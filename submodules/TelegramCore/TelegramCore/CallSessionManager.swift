import Foundation
#if os(macOS)
    import PostboxMac
    import MtProtoKitMac
    import SwiftSignalKitMac
#else
    import Postbox
    import MtProtoKitDynamic
    import SwiftSignalKit
#endif

public enum CallSessionError {
    case generic
    case privacyRestricted
    case notSupportedByPeer
    case serverProvided(String)
    case disconnected
}

public enum CallSessionEndedType {
    case hungUp
    case busy
    case missed
}

public enum CallSessionTerminationReason {
    case ended(CallSessionEndedType)
    case error(CallSessionError)
}

public struct ReportCallRating  {
    public let id:Int64
    public let accessHash:Int64
}

enum CallSessionInternalState {
    case ringing(id: Int64, accessHash: Int64, gAHash: Data, b: Data)
    case accepting(id: Int64, accessHash: Int64, gAHash: Data, b: Data, disposable: Disposable)
    case awaitingConfirmation(id: Int64, accessHash: Int64, gAHash: Data, b: Data, config: SecretChatEncryptionConfig)
    case requesting(a: Data, disposable: Disposable)
    case requested(id: Int64, accessHash: Int64, a: Data, gA: Data, config: SecretChatEncryptionConfig, remoteConfirmationTimestamp: Int32?)
    case confirming(id: Int64, accessHash: Int64, key: Data, keyId: Int64, keyVisualHash: Data, disposable: Disposable)
    case active(id: Int64, accessHash: Int64, beginTimestamp: Int32, key: Data, keyId: Int64, keyVisualHash: Data, connections: CallSessionConnectionSet)
    case dropping(Disposable)
    case terminated(reason: CallSessionTerminationReason, reportRating: ReportCallRating?)
}

public typealias CallSessionInternalId = UUID
typealias CallSessionStableId = Int64

public struct CallSessionRingingState: Equatable {
    public let id: CallSessionInternalId
    public let peerId: PeerId
    
    public static func ==(lhs: CallSessionRingingState, rhs: CallSessionRingingState) -> Bool {
        return lhs.id == rhs.id && lhs.peerId == rhs.peerId
    }
}

public enum DropCallReason {
    case hangUp
    case busy
    case disconnect
}

public enum CallSessionState {
    case ringing
    case accepting
    case requesting(ringing: Bool)
    case active(key: Data, keyVisualHash: Data, connections: CallSessionConnectionSet)
    case dropping
    case terminated(reason: CallSessionTerminationReason, reportRating: ReportCallRating?)
    
    fileprivate init(_ context: CallSessionContext) {
        switch context.state {
            case .ringing:
                self = .ringing
            case .accepting, .awaitingConfirmation:
                self = .accepting
            case .requesting, .confirming:
                self = .requesting(ringing: false)
            case let .requested(_, _, _, _, _, remoteConfirmationTimestamp):
                self = .requesting(ringing: remoteConfirmationTimestamp != nil)
            case let .active(_, _, _, key, _, keyVisualHash, connections):
                self = .active(key: key, keyVisualHash: keyVisualHash, connections: connections)
            case .dropping:
                self = .dropping
            case let .terminated(reason, reportRating):
                self = .terminated(reason: reason, reportRating: reportRating)
        }
    }
}

public struct CallSession {
    public let id: CallSessionInternalId
    public let isOutgoing: Bool
    public let state: CallSessionState
}

public struct CallSessionConnection {
    public let id: Int64
    public let ip: String
    public let ipv6: String
    public let port: Int32
    public let peerTag: Data
}

private func parseConnection(_ apiConnection: Api.PhoneConnection) -> CallSessionConnection {
    switch apiConnection {
        case let .phoneConnection(id, ip, ipv6, port, peerTag):
            return CallSessionConnection(id: id, ip: ip, ipv6: ipv6, port: port, peerTag: peerTag.makeData())
    }
}

public struct CallSessionConnectionSet {
    public let primary: CallSessionConnection
    public let alternatives: [CallSessionConnection]
}

private func parseConnectionSet(primary: Api.PhoneConnection, alternative: [Api.PhoneConnection]) -> CallSessionConnectionSet {
    return CallSessionConnectionSet(primary: parseConnection(primary), alternatives: alternative.map { parseConnection($0) })
}

private final class CallSessionContext {
    let peerId: PeerId
    let isOutgoing: Bool
    var state: CallSessionInternalState
    let subscribers = Bag<(CallSession) -> Void>()
    
    var isEmpty: Bool {
        if case .terminated = self.state {
            return self.subscribers.isEmpty
        } else {
            return false
        }
    }
    
    init(peerId: PeerId, isOutgoing: Bool, state: CallSessionInternalState) {
        self.peerId = peerId
        self.isOutgoing = isOutgoing
        self.state = state
    }
}

private final class CallSessionManagerContext {
    private let queue: Queue
    private let postbox: Postbox
    private let network: Network
    private let addUpdates: (Api.Updates) -> Void
    
    private let ringingSubscribers = Bag<([CallSessionRingingState]) -> Void>()
    private var contexts: [CallSessionInternalId: CallSessionContext] = [:]
    private var contextIdByStableId: [CallSessionStableId: CallSessionInternalId] = [:]
    
    private let disposables = DisposableSet()
    
    init(queue: Queue, postbox: Postbox, network: Network, addUpdates: @escaping (Api.Updates) -> Void) {
        self.queue = queue
        self.postbox = postbox
        self.network = network
        self.addUpdates = addUpdates
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.disposables.dispose()
    }
    
    func ringingStates() -> Signal<[CallSessionRingingState], NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            queue.async {
                if let strongSelf = self {
                    let index = strongSelf.ringingSubscribers.add { next in
                        subscriber.putNext(next)
                    }
                    subscriber.putNext(strongSelf.ringingStatesValue())
                    disposable.set(ActionDisposable {
                        queue.async {
                            if let strongSelf = self {
                                strongSelf.ringingSubscribers.remove(index)
                            }
                        }
                    })
                }
            }
            return disposable
        }
    }
    
    func callState(internalId: CallSessionInternalId) -> Signal<CallSession, NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            queue.async {
                if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                    let index = context.subscribers.add { next in
                        subscriber.putNext(next)
                    }
                    subscriber.putNext(CallSession(id: internalId, isOutgoing: context.isOutgoing, state: CallSessionState(context)))
                    disposable.set(ActionDisposable {
                        queue.async {
                            if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                                context.subscribers.remove(index)
                                if context.isEmpty {
                                    strongSelf.contexts.removeValue(forKey: internalId)
                                }
                            }
                        }
                    })
                }
            }
            return disposable
        }
    }
    
    private func ringingStatesValue() -> [CallSessionRingingState] {
        var ringingContexts: [CallSessionRingingState] = []
        for (id, context) in self.contexts {
            if case .ringing = context.state {
                ringingContexts.append(CallSessionRingingState(id: id, peerId: context.peerId))
            }
        }
        return ringingContexts
    }
    
    private func ringingStatesUpdated() {
        let states = self.ringingStatesValue()
        for subscriber in self.ringingSubscribers.copyItems() {
            subscriber(states)
        }
    }
    
    private func contextUpdated(internalId: CallSessionInternalId) {
        if let context = self.contexts[internalId] {
            let session = CallSession(id: internalId, isOutgoing: context.isOutgoing, state: CallSessionState(context))
            for subscriber in context.subscribers.copyItems() {
                subscriber(session)
            }
        }
    }
    
    private func addIncoming(peerId: PeerId, stableId: CallSessionStableId, accessHash: Int64, timestamp: Int32, gAHash: Data) {
        if self.contextIdByStableId[stableId] != nil {
            return
        }
        
        let bBytes = malloc(256)!
        let randomStatus = SecRandomCopyBytes(nil, 256, bBytes.assumingMemoryBound(to: UInt8.self))
        let b = Data(bytesNoCopy: bBytes, count: 256, deallocator: .free)
        
        if randomStatus == 0 {
            let internalId = CallSessionInternalId()
            self.contexts[internalId] = CallSessionContext(peerId: peerId, isOutgoing: false, state: .ringing(id: stableId, accessHash: accessHash, gAHash: gAHash, b: b))
            self.contextIdByStableId[stableId] = internalId
            self.contextUpdated(internalId: internalId)
            self.ringingStatesUpdated()
        }
    }
    
    func drop(internalId: CallSessionInternalId, reason: DropCallReason) {
        if let context = self.contexts[internalId] {
            var dropData: (CallSessionStableId, Int64, DropCallSessionReason)?
            var wasRinging = false
            switch context.state {
                case let .ringing(id, accessHash, _, _):
                    wasRinging = true
                    dropData = (id, accessHash, .busy)
                case let .accepting(id, accessHash, _, _, disposable):
                    dropData = (id, accessHash, .abort)
                    disposable.dispose()
                case let .active(id, accessHash, beginTimestamp, _, _, _, _):
                    let duration = max(0, Int32(CFAbsoluteTimeGetCurrent()) - beginTimestamp)
                    let internalReason: DropCallSessionReason
                    switch reason {
                        case .busy, .hangUp:
                            internalReason = .hangUp(duration)
                        case .disconnect:
                            internalReason = .disconnect
                    }
                    dropData = (id, accessHash, internalReason)
                case .dropping, .terminated:
                    break
                case let .awaitingConfirmation(id, accessHash, _, _, _):
                    dropData = (id, accessHash, .abort)
                case let .confirming(id, accessHash, _, _, _, disposable):
                    disposable.dispose()
                    dropData = (id, accessHash, .abort)
                case let .requested(id, accessHash, _, _, _, _):
                    dropData = (id, accessHash, .busy)
                case let .requesting(_, disposable):
                    disposable.dispose()
                    context.state = .terminated(reason: .ended(.hungUp), reportRating: nil)
                    self.contextUpdated(internalId: internalId)
                    if context.isEmpty {
                        self.contexts.removeValue(forKey: internalId)
                    }
            }
            
            if let (id, accessHash, reason) = dropData {
                self.contextIdByStableId.removeValue(forKey: id)
                context.state = .dropping((dropCallSession(network: self.network, addUpdates: self.addUpdates, stableId: id, accessHash: accessHash, reason: reason) |> deliverOn(self.queue)).start(next: { [weak self] reportRating in
                    if let strongSelf = self {
                        if let context = strongSelf.contexts[internalId] {
                            context.state = .terminated(reason: .ended(.hungUp), reportRating: reportRating ? ReportCallRating(id: id, accessHash: accessHash) : nil)
                            strongSelf.contextUpdated(internalId: internalId)
                            if context.isEmpty {
                                strongSelf.contexts.removeValue(forKey: internalId)
                            }
                        }
                    }
                }))
                self.contextUpdated(internalId: internalId)
                if wasRinging {
                    self.ringingStatesUpdated()
                }
            }
        }
    }
    
    func drop(stableId: CallSessionStableId, reason: DropCallReason) {
        if let internalId = self.contextIdByStableId[stableId] {
            self.contextIdByStableId.removeValue(forKey: stableId)
            self.drop(internalId: internalId, reason: reason)
        }
    }
    
    func dropAll() {
        let contexts = self.contexts
        for (internalId, context) in contexts {
            self.drop(internalId: internalId, reason: .hangUp)
        }
    }
    
    func accept(internalId: CallSessionInternalId) {
        if let context = self.contexts[internalId] {
            switch context.state {
                case let .ringing(id, accessHash, gAHash, b):
                    context.state = .accepting(id: id, accessHash: accessHash, gAHash: gAHash, b: b, disposable: (acceptCallSession(postbox: self.postbox, network: self.network, stableId: id, accessHash: accessHash, b: b) |> deliverOn(self.queue)).start(next: { [weak self] result in
                        if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                            if case .accepting = context.state {
                                switch result {
                                    case .failed:
                                        strongSelf.drop(internalId: internalId, reason: .disconnect)
                                    case let .success(call):
                                        switch call {
                                            case let .waiting(config):
                                                context.state = .awaitingConfirmation(id: id, accessHash: accessHash, gAHash: gAHash, b: b, config: config)
                                                strongSelf.contextUpdated(internalId: internalId)
                                            case let .call(config, gA, timestamp, connections):
                                                if let (key, keyId, keyVisualHash) = strongSelf.makeSessionEncryptionKey(config: config, gAHash: gAHash, b: b, gA: gA) {
                                                    context.state = .active(id: id, accessHash: accessHash, beginTimestamp: timestamp, key: key, keyId: keyId, keyVisualHash: keyVisualHash, connections: connections)
                                                    strongSelf.contextUpdated(internalId: internalId)
                                                } else {
                                                    strongSelf.drop(internalId: internalId, reason: .disconnect)
                                                }
                                        }
                                }
                            }
                        }
                    }))
                    self.contextUpdated(internalId: internalId)
                    self.ringingStatesUpdated()
                default:
                    break
            }
        }
    }
    
    func updateSession(_ call: Api.PhoneCall) {
        switch call {
            case .phoneCallEmpty:
                break
            case let .phoneCallAccepted(id, _, _, _, _, gB, _):
                if let internalId = self.contextIdByStableId[id] {
                    if let context = self.contexts[internalId] {
                        switch context.state {
                            case let .requested(_, accessHash, a, gA, config, _):
                                var key = MTExp(gB.makeData(), a, config.p.makeData())!
                                
                                if key.count > 256 {
                                    key.count = 256
                                } else  {
                                    while key.count < 256 {
                                        key.insert(0, at: 0)
                                    }
                                }
                                
                                let keyHash = MTSha1(key)!
                                
                                var keyId: Int64 = 0
                                keyHash.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
                                    memcpy(&keyId, bytes.advanced(by: keyHash.count - 8), 8)
                                }
                                
                                let keyVisualHash = MTSha256(key + gA)!
                            
                                context.state = .confirming(id: id, accessHash: accessHash, key: key, keyId: keyId, keyVisualHash: keyVisualHash, disposable: (confirmCallSession(network: self.network, stableId: id, accessHash: accessHash, gA: gA, keyFingerprint: keyId) |> deliverOnMainQueue).start(next: { [weak self] updatedCall in
                                    if let strongSelf = self, let context = strongSelf.contexts[internalId], case .confirming = context.state {
                                        if let updatedCall = updatedCall {
                                            strongSelf.updateSession(updatedCall)
                                        } else {
                                            strongSelf.drop(internalId: internalId, reason: .disconnect)
                                        }
                                    }
                                }))
                                self.contextUpdated(internalId: internalId)
                            default:
                                self.drop(internalId: internalId, reason: .disconnect)
                        }
                    } else {
                        assertionFailure()
                    }
                }
            case let .phoneCallDiscarded(flags, id, reason, duration):
                let reportRating = (flags & (1 << 2)) != 0
                if let internalId = self.contextIdByStableId[id] {
                    if let context = self.contexts[internalId] {
                        let parsedReason: CallSessionTerminationReason
                        if let reason = reason {
                            switch reason {
                                case .phoneCallDiscardReasonBusy:
                                    parsedReason = .ended(.busy)
                                case .phoneCallDiscardReasonDisconnect:
                                    parsedReason = .error(.disconnected)
                                case .phoneCallDiscardReasonHangup:
                                    parsedReason = .ended(.hungUp)
                                case .phoneCallDiscardReasonMissed:
                                    parsedReason = .ended(.missed)
                            }
                        } else {
                            parsedReason = .ended(.hungUp)
                        }
                        
    
                        switch context.state {
                            case let .accepting(id, accessHash, _, _, disposable):
                                disposable.dispose()
                                context.state = .terminated(reason: parsedReason, reportRating: reportRating ? ReportCallRating(id: id, accessHash: accessHash) : nil)
                                self.contextUpdated(internalId: internalId)
                            case .active(let id, let accessHash, _, _, _, _, _):
                                context.state = .terminated(reason: parsedReason, reportRating:  reportRating ? ReportCallRating(id: id, accessHash: accessHash) : nil)
                                self.contextUpdated(internalId: internalId)
                            case .awaitingConfirmation(let id, let accessHash, _, _, _):
                                context.state = .terminated(reason: parsedReason, reportRating:  reportRating ? ReportCallRating(id: id, accessHash: accessHash) : nil)
                                self.contextUpdated(internalId: internalId)
                            case .requested(let id, let accessHash, _, _, _, _):
                                context.state = .terminated(reason: parsedReason, reportRating:  reportRating ? ReportCallRating(id: id, accessHash: accessHash) : nil)
                                self.contextUpdated(internalId: internalId)
                            case let .confirming(id, accessHash, _, _, _, disposable):
                                disposable.dispose()
                                context.state = .terminated(reason: parsedReason, reportRating:  reportRating ? ReportCallRating(id: id, accessHash: accessHash) : nil)
                                self.contextUpdated(internalId: internalId)
                            case let .requesting(_, disposable):
                                disposable.dispose()
                                context.state = .terminated(reason: parsedReason, reportRating: nil)
                                self.contextUpdated(internalId: internalId)
                            case .ringing(let id, let accesshash, _, _):
                                context.state = .terminated(reason: parsedReason, reportRating:  reportRating ? ReportCallRating(id: id, accessHash: accesshash) : nil)
                                self.ringingStatesUpdated()
                                self.contextUpdated(internalId: internalId)
                            case .dropping, .terminated:
                                break
                        }
                    } else {
                        //assertionFailure()
                    }
                }
            case let .phoneCall(id, _, _, _, _, gAOrB, keyFingerprint, _, connection, alternativeConnections, startDate):
                if let internalId = self.contextIdByStableId[id] {
                    if let context = self.contexts[internalId] {
                        switch context.state {
                            case .accepting, .active, .dropping, .requesting, .ringing, .terminated, .requested:
                                break
                            case let .awaitingConfirmation(_, accessHash, gAHash, b, config):
                                if let (key, calculatedKeyId, keyVisualHash) = self.makeSessionEncryptionKey(config: config, gAHash: gAHash, b: b, gA: gAOrB.makeData()) {
                                    if keyFingerprint == calculatedKeyId {
                                        context.state = .active(id: id, accessHash: accessHash, beginTimestamp: startDate, key: key, keyId: calculatedKeyId, keyVisualHash: keyVisualHash, connections: parseConnectionSet(primary: connection, alternative: alternativeConnections))
                                        self.contextUpdated(internalId: internalId)
                                    } else {
                                        self.drop(internalId: internalId, reason: .disconnect)
                                    }
                                } else {
                                    self.drop(internalId: internalId, reason: .disconnect)
                                }
                            case let .confirming(id, accessHash, key, keyId, keyVisualHash, _):
                                context.state = .active(id: id, accessHash: accessHash, beginTimestamp: startDate, key: key, keyId: keyId, keyVisualHash: keyVisualHash, connections: parseConnectionSet(primary: connection, alternative: alternativeConnections))
                                self.contextUpdated(internalId: internalId)
                        }
                    } else {
                        assertionFailure()
                    }
                }
            case let .phoneCallRequested(id, accessHash, date, adminId, _, gAHash, _):
                if self.contextIdByStableId[id] == nil {
                    self.addIncoming(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: adminId), stableId: id, accessHash: accessHash, timestamp: date, gAHash: gAHash.makeData())
                }
            case let .phoneCallWaiting(_, id, _, _, _, _, _, receiveDate):
                if let internalId = self.contextIdByStableId[id] {
                    if let context = self.contexts[internalId] {
                        switch context.state {
                            case let .requested(id, accessHash, a, gA, config, remoteConfirmationTimestamp):
                                if let receiveDate = receiveDate, remoteConfirmationTimestamp == nil {
                                    context.state = .requested(id: id, accessHash: accessHash, a: a, gA: gA, config: config, remoteConfirmationTimestamp: receiveDate)
                                    self.contextUpdated(internalId: internalId)
                                }
                            default:
                                break
                        }
                    } else {
                        assertionFailure()
                    }
                }
        }
    }
    
    private func makeSessionEncryptionKey(config: SecretChatEncryptionConfig, gAHash: Data, b: Data, gA: Data) -> (key: Data, keyId: Int64, keyVisualHash: Data)? {
        var key = MTExp(gA, b, config.p.makeData())!
        
        if key.count > 256 {
            key.count = 256
        } else  {
            while key.count < 256 {
                key.insert(0, at: 0)
            }
        }
        
        let keyHash = MTSha1(key)!
        
        var keyId: Int64 = 0
        keyHash.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
            memcpy(&keyId, bytes.advanced(by: keyHash.count - 8), 8)
        }
        
        if MTSha256(gA)! != gAHash {
            return nil
        }
        
        let keyVisualHash = MTSha256(key + gA)!
        
        return (key, keyId, keyVisualHash)
    }
    
    func request(peerId: PeerId, internalId: CallSessionInternalId) -> CallSessionInternalId? {
        let aBytes = malloc(256)!
        let randomStatus = SecRandomCopyBytes(nil, 256, aBytes.assumingMemoryBound(to: UInt8.self))
        let a = Data(bytesNoCopy: aBytes, count: 256, deallocator: .free)
        if randomStatus == 0 {
            self.contexts[internalId] = CallSessionContext(peerId: peerId, isOutgoing: true, state: .requesting(a: a, disposable: (requestCallSession(postbox: self.postbox, network: self.network, peerId: peerId, a: a) |> deliverOn(queue)).start(next: { [weak self] result in
                if let strongSelf = self, let context = strongSelf.contexts[internalId] {
                    if case .requesting = context.state {
                        switch result {
                            case let .success(id, accessHash, config, gA, remoteConfirmationTimestamp):
                                context.state = .requested(id: id, accessHash: accessHash, a: a, gA: gA, config: config, remoteConfirmationTimestamp: remoteConfirmationTimestamp)
                                strongSelf.contextIdByStableId[id] = internalId
                                strongSelf.contextUpdated(internalId: internalId)
                            case let .failed(error):
                                context.state = .terminated(reason: .error(error), reportRating: nil)
                                strongSelf.contextUpdated(internalId: internalId)
                                if context.isEmpty {
                                    strongSelf.contexts.removeValue(forKey: internalId)
                                }
                        }
                    }
                }
            })))
            self.contextUpdated(internalId: internalId)
            return internalId
        } else {
            return nil
        }
    }
}

public enum CallRequestError {
    case generic
}

public final class CallSessionManager {
    private let queue = Queue()
    private var contextRef: Unmanaged<CallSessionManagerContext>?
    
    init(postbox: Postbox, network: Network, addUpdates: @escaping (Api.Updates) -> Void) {
        self.queue.async {
            let context = CallSessionManagerContext(queue: self.queue, postbox: postbox, network: network, addUpdates: addUpdates)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    deinit {
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
    }
    
    private func withContext(_ f: @escaping (CallSessionManagerContext) -> Void) {
        self.queue.async {
            if let contextRef = self.contextRef {
                let context = contextRef.takeUnretainedValue()
                f(context)
            }
        }
    }
    
    func updateSession(_ call: Api.PhoneCall) {
        self.withContext { context in
            context.updateSession(call)
        }
    }
    
    public func drop(internalId: CallSessionInternalId, reason: DropCallReason) {
        self.withContext { context in
            context.drop(internalId: internalId, reason: reason)
        }
    }
    
    func drop(stableId: CallSessionStableId, reason: DropCallReason) {
        self.withContext { context in
            context.drop(stableId: stableId, reason: reason)
        }
    }
    
    func dropAll() {
        self.withContext { context in
            context.dropAll()
        }
    }
    
    public func accept(internalId: CallSessionInternalId) {
        self.withContext { context in
            context.accept(internalId: internalId)
        }
    }
    
    public func request(peerId: PeerId, internalId: CallSessionInternalId = CallSessionInternalId()) -> Signal<CallSessionInternalId, NoError> {
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            
            self?.withContext { context in
                if let internalId = context.request(peerId: peerId, internalId: internalId) {
                    subscriber.putNext(internalId)
                    subscriber.putCompletion()
                }
            }
            
            return disposable
        }
    }
    
    public func ringingStates() -> Signal<[CallSessionRingingState], NoError> {
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            self?.withContext { context in
                disposable.set(context.ringingStates().start(next: { next in
                    subscriber.putNext(next)
                }))
            }
            return disposable
        }
    }
    
    public func callState(internalId: CallSessionInternalId) -> Signal<CallSession, NoError> {
        return Signal { [weak self] subscriber in
            let disposable = MetaDisposable()
            self?.withContext { context in
                disposable.set(context.callState(internalId: internalId).start(next: { next in
                    subscriber.putNext(next)
                }))
            }
            return disposable
        }
    }
}

private enum AcceptedCall {
    case waiting(config: SecretChatEncryptionConfig)
    case call(config: SecretChatEncryptionConfig, gA: Data, timestamp: Int32, connections: CallSessionConnectionSet)
}

private enum AcceptCallResult {
    case failed
    case success(AcceptedCall)
}

private func acceptCallSession(postbox: Postbox, network: Network, stableId: CallSessionStableId, accessHash: Int64, b: Data) -> Signal<AcceptCallResult, NoError> {
    return validatedEncryptionConfig(postbox: postbox, network: network)
        |> mapToSignal { config in
            var gValue: Int32 = config.g.byteSwapped
            let g = Data(bytes: &gValue, count: 4)
            let p = config.p.makeData()
            
            let bData = b
            
            let gb = MTExp(g, bData, p)!
            
            return network.request(Api.functions.phone.acceptCall(peer: .inputPhoneCall(id: stableId, accessHash: accessHash), gB: Buffer(data: gb), protocol: .phoneCallProtocol(flags: (1 << 0) | (1 << 1), minLayer: 65, maxLayer: 66)))
                |> map { Optional($0) }
                |> `catch` { _ -> Signal<Api.phone.PhoneCall?, NoError> in
                    return .single(nil)
                }
                |> mapToSignal { call -> Signal<AcceptCallResult, NoError> in
                    if let call = call {
                        return postbox.modify { modifier -> AcceptCallResult in
                            switch call {
                                case let .phoneCall(phoneCall, users):
                                    var parsedUsers: [Peer] = []
                                    for user in users {
                                        parsedUsers.append(TelegramUser(user: user))
                                    }
                                    updatePeers(modifier: modifier, peers: parsedUsers, update: { _, updated in
                                        return updated
                                    })
                                    
                                    switch phoneCall {
                                        case .phoneCallEmpty, .phoneCallRequested, .phoneCallAccepted, .phoneCallDiscarded:
                                            return .failed
                                        case .phoneCallWaiting:
                                            return .success(.waiting(config: config))
                                        case let .phoneCall(id, _, _, _, _, gAOrB, keyFingerprint, `protocol`, connection, alternativeConnections, startDate):
                                            if id == stableId {
                                                return .success(.call(config: config, gA: gAOrB.makeData(), timestamp: startDate, connections: parseConnectionSet(primary: connection, alternative: alternativeConnections)))
                                            } else {
                                                return .failed
                                            }
                                    }
                            }
                        }
                    } else {
                        return .single(.failed)
                    }
                }
        }
}

private enum RequestCallSessionResult {
    case success(id: CallSessionStableId, accessHash: Int64, config: SecretChatEncryptionConfig, gA: Data, remoteConfirmationTimestamp: Int32?)
    case failed(CallSessionError)
}

private func requestCallSession(postbox: Postbox, network: Network, peerId: PeerId, a: Data) -> Signal<RequestCallSessionResult, NoError> {
    return validatedEncryptionConfig(postbox: postbox, network: network)
        |> mapToSignal { config -> Signal<RequestCallSessionResult, NoError> in
            return postbox.modify { modifier -> Signal<RequestCallSessionResult, NoError> in
                if let peer = modifier.getPeer(peerId), let inputUser = apiInputUser(peer) {
                    var gValue: Int32 = config.g.byteSwapped
                    let g = Data(bytes: &gValue, count: 4)
                    let p = config.p.makeData()
                    
                    let ga = MTExp(g, a, p)!
                    
                    let gAHash = MTSha256(ga)!
                    
                    return network.request(Api.functions.phone.requestCall(userId: inputUser, randomId: Int32(bitPattern: arc4random()), gAHash: Buffer(data: gAHash), protocol: .phoneCallProtocol(flags: (1 << 0) | (1 << 1), minLayer: 65, maxLayer: 66)))
                        |> map { result -> RequestCallSessionResult in
                            switch result {
                                case let .phoneCall(phoneCall, _):
                                    switch phoneCall {
                                        case let .phoneCallRequested(id, accessHash, _, _, _, _, _):
                                            return .success(id: id, accessHash: accessHash, config: config, gA: ga, remoteConfirmationTimestamp: nil)
                                        case let .phoneCallWaiting(_, id, accessHash, _, _, _, _, receiveDate):
                                            return .success(id: id, accessHash: accessHash, config: config, gA: ga, remoteConfirmationTimestamp: receiveDate)
                                        default:
                                            return .failed(.generic)
                                    }
                            }
                        }
                        |> `catch` { error -> Signal<RequestCallSessionResult, NoError> in
                            switch error.errorDescription {
                                case "PARTICIPANT_VERSION_OUTDATED":
                                    return .single(.failed(.notSupportedByPeer))
                                case "USER_PRIVACY_RESTRICTED":
                                    return .single(.failed(.privacyRestricted))
                                default:
                                    if error.errorCode == 406 {
                                        return .single(.failed(.serverProvided(error.errorDescription)))
                                    } else {
                                        return .single(.failed(.generic))
                                    }
                            }
                        }
                } else {
                    return .single(.failed(.generic))
                }
            } |> switchToLatest
        }
}

private func confirmCallSession(network: Network, stableId: CallSessionStableId, accessHash: Int64, gA: Data, keyFingerprint: Int64) -> Signal<Api.PhoneCall?, NoError> {
    return network.request(Api.functions.phone.confirmCall(peer: Api.InputPhoneCall.inputPhoneCall(id: stableId, accessHash: accessHash), gA: Buffer(data: gA), keyFingerprint: keyFingerprint, protocol: .phoneCallProtocol(flags: (1 << 0) | (1 << 1), minLayer: 65, maxLayer: 66)))
        |> map { Optional($0) }
        |> `catch` { _ -> Signal<Api.phone.PhoneCall?, NoError> in
            return .single(nil)
        }
        |> map { result -> Api.PhoneCall? in
            if let result = result {
                switch result {
                    case let .phoneCall(phoneCall, _):
                        return phoneCall
                }
            } else {
                return nil
            }
        }
}

private enum DropCallSessionReason {
    case abort
    case hangUp(Int32)
    case busy
    case disconnect
}

private func dropCallSession(network: Network, addUpdates: @escaping (Api.Updates) -> Void, stableId: CallSessionStableId, accessHash: Int64, reason: DropCallSessionReason) -> Signal<Bool, NoError> {
    var mappedReason: Api.PhoneCallDiscardReason
    var duration: Int32 = 0
    switch reason {
        case .abort:
            mappedReason = .phoneCallDiscardReasonHangup
        case let .hangUp(value):
            duration = value
            mappedReason = .phoneCallDiscardReasonHangup
        case .busy:
            mappedReason = .phoneCallDiscardReasonBusy
        case .disconnect:
            mappedReason = .phoneCallDiscardReasonDisconnect
    }
    return network.request(Api.functions.phone.discardCall(peer: Api.InputPhoneCall.inputPhoneCall(id: stableId, accessHash: accessHash), duration: duration, reason: mappedReason, connectionId: 0))
        |> map { Optional($0) }
        |> `catch` { _ -> Signal<Api.Updates?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { updates -> Signal<Bool, NoError> in
            var report:Bool = false
            if let updates = updates {
                switch updates {
                case .updates(let updates, _, _, _, _):
                    for update in updates {
                        switch update {
                        case .updatePhoneCall(let phoneCall):
                            switch phoneCall {
                            case.phoneCallDiscarded(let values):
                                report = (values.flags & (1 << 2)) != 0
                            default:
                                break
                            }
                            break
                        default:
                            break
                        }
                    }
                default:
                    break
                }

                addUpdates(updates)
                
            }
            return .single(report)
        }
}
