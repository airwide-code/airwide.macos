import Foundation

private let traceReadStates = false

enum ApplyInteractiveMaxReadIdResult {
    case None
    case Push(thenSync: Bool)
}

private final class InternalPeerReadStates {
    var namespaces: [MessageId.Namespace: PeerReadState]
    
    init(namespaces: [MessageId.Namespace: PeerReadState]) {
        self.namespaces = namespaces
    }
}

final class MessageHistoryReadStateTable: Table {
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .int64)
    }
    
    private var cachedPeerReadStates: [PeerId: InternalPeerReadStates?] = [:]
    private var updatedInitialPeerReadStates: [PeerId: [MessageId.Namespace: PeerReadState]] = [:]
    
    private let sharedKey = ValueBoxKey(length: 8)
    
    private func key(_ id: PeerId) -> ValueBoxKey {
        self.sharedKey.setInt64(0, value: id.toInt64())
        return self.sharedKey
    }
    
    override init(valueBox: ValueBox, table: ValueBoxTable) {
        super.init(valueBox: valueBox, table: table)
    }

    private func get(_ id: PeerId) -> InternalPeerReadStates? {
        if let states = self.cachedPeerReadStates[id] {
            return states
        } else {
            if let value = self.valueBox.get(self.table, key: self.key(id)) {
                var count: Int32 = 0
                value.read(&count, offset: 0, length: 4)
                var stateByNamespace: [MessageId.Namespace: PeerReadState] = [:]
                for _ in 0 ..< count {
                    var namespaceId: Int32 = 0
                    value.read(&namespaceId, offset: 0, length: 4)
                    
                    let state: PeerReadState
                    var kind: Int8 = 0
                    value.read(&kind, offset: 0, length: 1)
                    if kind == 0 {
                        var maxIncomingReadId: Int32 = 0
                        var maxOutgoingReadId: Int32 = 0
                        var maxKnownId: Int32 = 0
                        var count: Int32 = 0
                        
                        value.read(&maxIncomingReadId, offset: 0, length: 4)
                        value.read(&maxOutgoingReadId, offset: 0, length: 4)
                        value.read(&maxKnownId, offset: 0, length: 4)
                        value.read(&count, offset: 0, length: 4)
                        
                        state = .idBased(maxIncomingReadId: maxIncomingReadId, maxOutgoingReadId: maxOutgoingReadId, maxKnownId: maxKnownId, count: count)
                    } else {
                        var maxIncomingReadTimestamp: Int32 = 0
                        var maxIncomingReadIdPeerId: Int64 = 0
                        var maxIncomingReadIdNamespace: Int32 = 0
                        var maxIncomingReadIdId: Int32 = 0
                        
                        var maxOutgoingReadTimestamp: Int32 = 0
                        var maxOutgoingReadIdPeerId: Int64 = 0
                        var maxOutgoingReadIdNamespace: Int32 = 0
                        var maxOutgoingReadIdId: Int32 = 0
                        
                        var count: Int32 = 0
                        
                        value.read(&maxIncomingReadTimestamp, offset: 0, length: 4)
                        value.read(&maxIncomingReadIdPeerId, offset: 0, length: 8)
                        value.read(&maxIncomingReadIdNamespace, offset: 0, length: 4)
                        value.read(&maxIncomingReadIdId, offset: 0, length: 4)
                        
                        value.read(&maxOutgoingReadTimestamp, offset: 0, length: 4)
                        value.read(&maxOutgoingReadIdPeerId, offset: 0, length: 8)
                        value.read(&maxOutgoingReadIdNamespace, offset: 0, length: 4)
                        value.read(&maxOutgoingReadIdId, offset: 0, length: 4)
                        
                        value.read(&count, offset: 0, length: 4)
                        
                        state = .indexBased(maxIncomingReadIndex: MessageIndex(id: MessageId(peerId: PeerId(maxIncomingReadIdPeerId), namespace: maxIncomingReadIdNamespace, id: maxIncomingReadIdId), timestamp: maxIncomingReadTimestamp), maxOutgoingReadIndex: MessageIndex(id: MessageId(peerId: PeerId(maxOutgoingReadIdPeerId), namespace: maxOutgoingReadIdNamespace, id: maxOutgoingReadIdId), timestamp: maxOutgoingReadTimestamp), count: count)
                    }
                    stateByNamespace[namespaceId] = state
                }
                let states = InternalPeerReadStates(namespaces: stateByNamespace)
                self.cachedPeerReadStates[id] = states
                return states
            } else {
                self.cachedPeerReadStates[id] = nil
                return nil
            }
        }
    }
    
    func getCombinedState(_ peerId: PeerId) -> CombinedPeerReadState? {
        if let states = self.get(peerId) {
            return CombinedPeerReadState(states: states.namespaces.map({$0}))
        }
        return nil
    }
    
    private func markReadStatesAsUpdated(_ peerId: PeerId, namespaces: [MessageId.Namespace: PeerReadState]) {
        if self.updatedInitialPeerReadStates[peerId] == nil {
            self.updatedInitialPeerReadStates[peerId] = namespaces
        }
    }
    
    func resetStates(_ peerId: PeerId, namespaces: [MessageId.Namespace: PeerReadState]) -> CombinedPeerReadState? {
        if traceReadStates {
            print("[ReadStateTable] resetStates peerId: \(peerId), namespaces: \(namespaces)")
        }
        
        if let states = self.get(peerId) {
            var updated = false
            for (namespace, state) in namespaces {
                if states.namespaces[namespace] == nil || states.namespaces[namespace]! != state {
                    self.markReadStatesAsUpdated(peerId, namespaces: states.namespaces)
                    updated = true
                }
                states.namespaces[namespace] = state
            }
            if updated {
                return CombinedPeerReadState(states: states.namespaces.map({$0}))
            } else {
                return nil
            }
        } else {
            self.markReadStatesAsUpdated(peerId, namespaces: [:])
            let states = InternalPeerReadStates(namespaces: namespaces)
            self.cachedPeerReadStates[peerId] = states
            return CombinedPeerReadState(states: states.namespaces.map({$0}))
        }
    }
    
    func addIncomingMessages(_ peerId: PeerId, indices: Set<MessageIndex>) -> (CombinedPeerReadState?, Bool) {
        var indicesByNamespace: [MessageId.Namespace: [MessageIndex]] = [:]
        for index in indices {
            if indicesByNamespace[index.id.namespace] != nil {
                indicesByNamespace[index.id.namespace]!.append(index)
            } else {
                indicesByNamespace[index.id.namespace] = [index]
            }
        }
        
        if let states = self.get(peerId) {
            if traceReadStates {
                print("[ReadStateTable] addIncomingMessages peerId: \(peerId), indices: \(indices) (before: \(states.namespaces))")
            }
            
            var updated = false
            let invalidated = false
            for (namespace, namespaceIndices) in indicesByNamespace {
                if let currentState = states.namespaces[namespace] {
                    var addedUnreadCount: Int32 = 0
                    for index in namespaceIndices {
                        switch currentState {
                            case let .idBased(maxIncomingReadId, _, maxKnownId, _):
                                if index.id.id > maxKnownId && index.id.id > maxIncomingReadId {
                                    addedUnreadCount += 1
                                }
                            case let .indexBased(maxIncomingReadIndex, _, _):
                                if index > maxIncomingReadIndex {
                                    addedUnreadCount += 1
                                }
                        }
                    }
                    
                    if addedUnreadCount != 0 {
                        self.markReadStatesAsUpdated(peerId, namespaces: states.namespaces)
                        
                        states.namespaces[namespace] = currentState.withAddedCount(addedUnreadCount)
                        updated = true
                        
                        if traceReadStates {
                            print("[ReadStateTable] added \(addedUnreadCount)")
                        }
                    }
                }
            }
            
            return (updated ? CombinedPeerReadState(states: states.namespaces.map({$0})) : nil, invalidated)
        } else {
            if traceReadStates {
                print("[ReadStateTable] addIncomingMessages peerId: \(peerId), just invalidated)")
            }
            return (nil, true)
        }
    }
    
    func deleteMessages(_ peerId: PeerId, indices: [MessageIndex], incomingStatsInIndices: (PeerId, MessageId.Namespace, [MessageIndex]) -> (Int, Bool)) -> (CombinedPeerReadState?, Bool) {
        var indicesByNamespace: [MessageId.Namespace: [MessageIndex]] = [:]
        for index in indices {
            if indicesByNamespace[index.id.namespace] != nil {
                indicesByNamespace[index.id.namespace]!.append(index)
            } else {
                indicesByNamespace[index.id.namespace] = [index]
            }
        }
        
        if let states = self.get(peerId) {
            if traceReadStates {
                print("[ReadStateTable] deleteMessages peerId: \(peerId), ids: \(indices) (before: \(states.namespaces))")
            }
            
            var updated = false
            var invalidate = false
            for (namespace, namespaceIndices) in indicesByNamespace {
                if let currentState = states.namespaces[namespace] {
                    var unreadIndices: [MessageIndex] = []
                    for index in namespaceIndices {
                        if !currentState.isIncomingMessageIndexRead(index) {
                            unreadIndices.append(index)
                        }
                    }
                    
                    let (knownCount, holes) = incomingStatsInIndices(peerId, namespace, unreadIndices)
                    if holes {
                        invalidate = true
                    }
                    
                    self.markReadStatesAsUpdated(peerId, namespaces: states.namespaces)
                    
                    states.namespaces[namespace] = currentState.withAddedCount(Int32(-knownCount))
                    updated = true
                } else {
                    invalidate = true
                }
            }
            
            return (updated ? CombinedPeerReadState(states: states.namespaces.map({$0})) : nil, invalidate)
        } else {
            return (nil, true)
        }
    }
    
    func applyIncomingMaxReadId(_ messageId: MessageId, incomingStatsInRange: (MessageId.Namespace, MessageId.Id, MessageId.Id) -> (count: Int, holes: Bool), topMessageId: (MessageId.Id, Bool)?) -> (CombinedPeerReadState?, Bool) {
        if let states = self.get(messageId.peerId), let state = states.namespaces[messageId.namespace] {
            if traceReadStates {
                print("[ReadStateTable] applyMaxReadId peerId: \(messageId.peerId), maxReadId: \(messageId) (before: \(states.namespaces))")
            }
            
            switch state {
                case let .idBased(maxIncomingReadId, maxOutgoingReadId, maxKnownId, count):
                    if maxIncomingReadId < messageId.id || (topMessageId != nil && (messageId.id == topMessageId!.0 || topMessageId!.1) && state.count != 0) {
                        var (deltaCount, holes) = incomingStatsInRange(messageId.namespace, maxIncomingReadId + 1, messageId.id)
                        
                        if traceReadStates {
                            print("[ReadStateTable] applyMaxReadId after deltaCount: \(deltaCount), holes: \(holes)")
                        }
                        
                        if let topMessageId = topMessageId, (messageId.id == topMessageId.0 || topMessageId.1) {
                            if deltaCount != Int(state.count) {
                                deltaCount = Int(state.count)
                                holes = true
                            }
                        }
                        
                        self.markReadStatesAsUpdated(messageId.peerId, namespaces: states.namespaces)
                        
                        states.namespaces[messageId.namespace] = .idBased(maxIncomingReadId: messageId.id, maxOutgoingReadId: maxOutgoingReadId, maxKnownId: maxKnownId, count: count - Int32(deltaCount))
                        return (CombinedPeerReadState(states: states.namespaces.map({$0})), holes)
                }
                case .indexBased:
                    assertionFailure()
                    break
            }
        } else {
            return (nil, true)
        }
        
        return (nil, false)
    }
    
    func applyIncomingMaxReadIndex(_ messageIndex: MessageIndex, incomingStatsInRange: (MessageIndex, MessageIndex) -> (count: Int, holes: Bool, readMesageIds: [MessageId])) -> (CombinedPeerReadState?, Bool, [MessageId]) {
        if let states = self.get(messageIndex.id.peerId), let state = states.namespaces[messageIndex.id.namespace] {
            if traceReadStates {
                print("[ReadStateTable] applyIncomingMaxReadIndex peerId: \(messageIndex.id.peerId), maxReadIndex: \(messageIndex) (before: \(states.namespaces))")
            }
            
            switch state {
                case .idBased:
                    assertionFailure()
                case let .indexBased(maxIncomingReadIndex, maxOutgoingReadIndex, count):
                    if maxIncomingReadIndex < messageIndex {
                        let (deltaCount, holes, messageIds) = incomingStatsInRange(maxIncomingReadIndex.successor(), messageIndex)
                        
                        if traceReadStates {
                            print("[ReadStateTable] applyIncomingMaxReadIndex after deltaCount: \(deltaCount), holes: \(holes)")
                        }
                        
                        self.markReadStatesAsUpdated(messageIndex.id.peerId, namespaces: states.namespaces)
                        
                        states.namespaces[messageIndex.id.namespace] = .indexBased(maxIncomingReadIndex: messageIndex, maxOutgoingReadIndex: maxOutgoingReadIndex, count: count - Int32(deltaCount))
                        return (CombinedPeerReadState(states: states.namespaces.map({$0})), holes, messageIds)
                    }
            }
        } else {
            return (nil, true, [])
        }
        
        return (nil, false, [])
    }
    
    func applyOutgoingMaxReadId(_ messageId: MessageId) -> (CombinedPeerReadState?, Bool) {
        if let states = self.get(messageId.peerId), let state = states.namespaces[messageId.namespace] {
            switch state {
                case let .idBased(maxIncomingReadId, maxOutgoingReadId, maxKnownId, count):
                    if maxOutgoingReadId < messageId.id {
                        self.markReadStatesAsUpdated(messageId.peerId, namespaces: states.namespaces)
                        states.namespaces[messageId.namespace] = .idBased(maxIncomingReadId: maxIncomingReadId, maxOutgoingReadId: messageId.id, maxKnownId: maxKnownId, count: count)
                        return (CombinedPeerReadState(states: states.namespaces.map({$0})), false)
                    }
                case .indexBased:
                    assertionFailure()
                    break
            }
        } else {
            return (nil, true)
        }
        
        return (nil, false)
    }
    
    func applyOutgoingMaxReadIndex(_ messageIndex: MessageIndex, outgoingIndexStatsInRange: (MessageIndex, MessageIndex) -> [MessageId]) -> (CombinedPeerReadState?, Bool, [MessageId]) {
        if let states = self.get(messageIndex.id.peerId), let state = states.namespaces[messageIndex.id.namespace] {
            switch state {
                case .idBased:
                    assertionFailure()
                    break
                case let .indexBased(maxIncomingReadIndex, maxOutgoingReadIndex, count):
                    if maxOutgoingReadIndex < messageIndex {
                        let messageIds: [MessageId] = outgoingIndexStatsInRange(maxOutgoingReadIndex.successor(), messageIndex)
                        
                        self.markReadStatesAsUpdated(messageIndex.id.peerId, namespaces: states.namespaces)
                        states.namespaces[messageIndex.id.namespace] = .indexBased(maxIncomingReadIndex: maxIncomingReadIndex, maxOutgoingReadIndex: messageIndex, count: count)
                        return (CombinedPeerReadState(states: states.namespaces.map({$0})), false, messageIds)
                    }
            }
        } else {
            return (nil, true, [])
        }
        
        return (nil, false, [])
    }
    
    func applyInteractiveMaxReadIndex(_ messageIndex: MessageIndex, incomingStatsInRange: (MessageId.Namespace, MessageId.Id, MessageId.Id) -> (count: Int, holes: Bool), incomingIndexStatsInRange: (MessageIndex, MessageIndex) -> (count: Int, holes: Bool, readMesageIds: [MessageId]), topMessageId: (MessageId.Id, Bool)?, topMessageIndexByNamespace: (MessageId.Namespace) -> MessageIndex?) -> (combinedState: CombinedPeerReadState?, ApplyInteractiveMaxReadIdResult, readMesageIds: [MessageId]) {
        if let states = self.get(messageIndex.id.peerId) {
            if let state = states.namespaces[messageIndex.id.namespace] {
                switch state {
                    case .idBased:
                        let (combinedState, holes) = self.applyIncomingMaxReadId(messageIndex.id, incomingStatsInRange: incomingStatsInRange, topMessageId: topMessageId)
                        
                        if let combinedState = combinedState {
                            return (combinedState, .Push(thenSync: holes), [])
                        }
                        
                        return (combinedState, holes ? .Push(thenSync: true) : .None, [])
                    case .indexBased:
                        let (combinedState, holes, messageIds) = self.applyIncomingMaxReadIndex(messageIndex, incomingStatsInRange: incomingIndexStatsInRange)
                        
                        if let combinedState = combinedState {
                            return (combinedState, .Push(thenSync: holes), messageIds)
                        }
                        
                        return (combinedState, holes ? .Push(thenSync: true) : .None, messageIds)
                }
            } else {
                for (namespace, state) in states.namespaces {
                    if let topIndex = topMessageIndexByNamespace(namespace), topIndex <= messageIndex {
                        switch state {
                            case .idBased:
                                let (combinedState, holes) = self.applyIncomingMaxReadId(topIndex.id, incomingStatsInRange: incomingStatsInRange, topMessageId: nil)
                                
                                if let combinedState = combinedState {
                                    return (combinedState, .Push(thenSync: holes), [])
                                }
                                
                                return (combinedState, holes ? .Push(thenSync: true) : .None, [])
                            case .indexBased:
                                let (combinedState, holes, messageIds) = self.applyIncomingMaxReadIndex(topIndex, incomingStatsInRange: incomingIndexStatsInRange)
                                
                                if let combinedState = combinedState {
                                    return (combinedState, .Push(thenSync: holes), messageIds)
                                }
                                
                                return (combinedState, holes ? .Push(thenSync: true) : .None, messageIds)
                        }
                    }
                }
                return (nil, .Push(thenSync: true), [])
            }
        } else {
            return (nil, .Push(thenSync: true), [])
        }
    }
    
    func transactionUnreadCountDeltas() -> [PeerId: Int32] {
        var deltas: [PeerId: Int32] = [:]
        for (id, initialNamespaces) in self.updatedInitialPeerReadStates {
            var initialCount: Int32 = 0
            for (_, state) in initialNamespaces {
                initialCount += state.count
            }
            
            var updatedCount: Int32 = 0
            if let maybeStates = self.cachedPeerReadStates[id] {
                if let states = maybeStates {
                    for (_, state) in states.namespaces {
                        updatedCount += state.count
                    }
                }
            } else {
                assertionFailure()
            }
            
            if initialCount != updatedCount {
                deltas[id] = updatedCount - initialCount
            }
        }
        return deltas
    }
    
    func transactionPeerIdsWithUpdatedCombinedReadStates() -> Set<PeerId> {
        return Set(updatedInitialPeerReadStates.keys)
    }
    
    override func clearMemoryCache() {
        self.cachedPeerReadStates.removeAll()
        assert(self.updatedInitialPeerReadStates.isEmpty)
    }
    
    override func beforeCommit() {
        if !self.updatedInitialPeerReadStates.isEmpty {
            let sharedBuffer = WriteBuffer()
            for (id, initialNamespaces) in self.updatedInitialPeerReadStates {
                if let wrappedStates = self.cachedPeerReadStates[id], let states = wrappedStates {
                    sharedBuffer.reset()
                    var count: Int32 = Int32(states.namespaces.count)
                    sharedBuffer.write(&count, offset: 0, length: 4)
                    for (namespace, state) in states.namespaces {
                        var namespaceId: Int32 = namespace
                        sharedBuffer.write(&namespaceId, offset: 0, length: 4)
                        
                        switch state {
                            case var .idBased(maxIncomingReadId, maxOutgoingReadId, maxKnownId, count):
                                var kind: Int8 = 0
                                sharedBuffer.write(&kind, offset: 0, length: 1)
                                
                                sharedBuffer.write(&maxIncomingReadId, offset: 0, length: 4)
                                sharedBuffer.write(&maxOutgoingReadId, offset: 0, length: 4)
                                sharedBuffer.write(&maxKnownId, offset: 0, length: 4)
                                sharedBuffer.write(&count, offset: 0, length: 4)
                            case .indexBased(let maxIncomingReadIndex, let maxOutgoingReadIndex, var count):
                                var kind: Int8 = 1
                                sharedBuffer.write(&kind, offset: 0, length: 1)
                            
                                var maxIncomingReadTimestamp: Int32 = maxIncomingReadIndex.timestamp
                                var maxIncomingReadIdPeerId: Int64 = maxIncomingReadIndex.id.peerId.toInt64()
                                var maxIncomingReadIdNamespace: Int32 = maxIncomingReadIndex.id.namespace
                                var maxIncomingReadIdId: Int32 = maxIncomingReadIndex.id.id
                                
                                var maxOutgoingReadTimestamp: Int32 = maxOutgoingReadIndex.timestamp
                                var maxOutgoingReadIdPeerId: Int64 = maxOutgoingReadIndex.id.peerId.toInt64()
                                var maxOutgoingReadIdNamespace: Int32 = maxOutgoingReadIndex.id.namespace
                                var maxOutgoingReadIdId: Int32 = maxOutgoingReadIndex.id.id
                                
                                sharedBuffer.write(&maxIncomingReadTimestamp, offset: 0, length: 4)
                                sharedBuffer.write(&maxIncomingReadIdPeerId, offset: 0, length: 8)
                                sharedBuffer.write(&maxIncomingReadIdNamespace, offset: 0, length: 4)
                                sharedBuffer.write(&maxIncomingReadIdId, offset: 0, length: 4)
                                
                                sharedBuffer.write(&maxOutgoingReadTimestamp, offset: 0, length: 4)
                                sharedBuffer.write(&maxOutgoingReadIdPeerId, offset: 0, length: 8)
                                sharedBuffer.write(&maxOutgoingReadIdNamespace, offset: 0, length: 4)
                                sharedBuffer.write(&maxOutgoingReadIdId, offset: 0, length: 4)
                            
                                sharedBuffer.write(&count, offset: 0, length: 4)
                        }
                    }
                    self.valueBox.set(self.table, key: self.key(id), value: sharedBuffer)
                } else {
                    self.valueBox.remove(self.table, key: self.key(id))
                }
            }
            self.updatedInitialPeerReadStates.removeAll()
        }
    }
}
