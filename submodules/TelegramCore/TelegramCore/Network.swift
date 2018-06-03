import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
#else
    import Postbox
    import SwiftSignalKit
    import MtProtoKitDynamic
#endif
import TelegramCorePrivateModule

public enum ConnectionStatus: Equatable {
    case waitingForNetwork
    case connecting(toProxy: Bool)
    case updating
    case online
    
    public static func ==(lhs: ConnectionStatus, rhs: ConnectionStatus) -> Bool {
        switch lhs {
            case .waitingForNetwork:
                if case .waitingForNetwork = rhs {
                    return true
                } else {
                    return false
                }
            case let .connecting(toProxy):
                if case .connecting(toProxy) = rhs {
                    return true
                } else {
                    return false
                }
            case .updating:
                if case .updating = rhs {
                    return true
                } else {
                    return false
                }
            case .online:
                if case .online = rhs {
                    return true
                } else {
                    return false
                }
        }
    }
}

private struct MTProtoConnectionFlags: OptionSet {
    let rawValue: Int
    
    static let NetworkAvailable = MTProtoConnectionFlags(rawValue: 1)
    static let Connected = MTProtoConnectionFlags(rawValue: 2)
    static let UpdatingConnectionContext = MTProtoConnectionFlags(rawValue: 4)
    static let PerformingServiceTasks = MTProtoConnectionFlags(rawValue: 8)
    static let HasProxy = MTProtoConnectionFlags(rawValue: 16)
}

class WrappedRequestMetadata: NSObject {
    let metadata: CustomStringConvertible
    let tag: NetworkRequestDependencyTag?
    
    init(metadata: CustomStringConvertible, tag: NetworkRequestDependencyTag?) {
        self.metadata = metadata
        self.tag = tag
    }
    
    override var description: String {
        return self.metadata.description
    }
}

public protocol NetworkRequestDependencyTag {
    func shouldDependOn(other: NetworkRequestDependencyTag) -> Bool
}

private class MTProtoConnectionStatusDelegate: NSObject, MTProtoDelegate {
    var action: (MTProtoConnectionFlags) -> () = { _ in }
    let state = Atomic<MTProtoConnectionFlags>(value: [])
    
    @objc func mtProtoNetworkAvailabilityChanged(_ mtProto: MTProto!, isNetworkAvailable: Bool) {
        self.action(self.state.modify { flags in
            if isNetworkAvailable {
                return flags.union([.NetworkAvailable])
            } else {
                return flags.subtracting([.NetworkAvailable])
            }
        })
    }
    
    @objc func mtProtoConnectionStateChanged(_ mtProto: MTProto!, state: MTProtoConnectionState!) {
        self.action(self.state.modify { flags in
            var updatedFlags = flags
            if let state = state {
                if state.isConnected {
                    updatedFlags.insert(.Connected)
                } else {
                    updatedFlags.remove(.Connected)
                }
                if state.isUsingProxy {
                    updatedFlags.insert(.HasProxy)
                } else {
                    updatedFlags.remove(.HasProxy)
                }
            } else {
                updatedFlags.remove(.Connected)
                updatedFlags.remove(.HasProxy)
            }
            return updatedFlags
        })
    }
    
    @objc func mtProtoConnectionContextUpdateStateChanged(_ mtProto: MTProto!, isUpdatingConnectionContext: Bool) {
        self.action(self.state.modify { flags in
            if isUpdatingConnectionContext {
                return flags.union([.UpdatingConnectionContext])
            } else {
                return flags.subtracting([.UpdatingConnectionContext])
            }
        })
    }
    
    @objc func mtProtoServiceTasksStateChanged(_ mtProto: MTProto!, isPerformingServiceTasks: Bool) {
        self.action(self.state.modify { flags in
            if isPerformingServiceTasks {
                return flags.union([.PerformingServiceTasks])
            } else {
                return flags.subtracting([.PerformingServiceTasks])
            }
        })
    }
}

private var registeredLoggingFunctions: Void = {
    NetworkRegisterLoggingFunction()
    registerLoggingFunctions()
}()

private enum UsageCalculationConnection: Int32 {
    case cellular = 0
    case wifi = 1
}

private enum UsageCalculationDirection: Int32 {
    case incoming = 0
    case outgoing = 1
}

private struct UsageCalculationTag {
    let connection: UsageCalculationConnection
    let direction: UsageCalculationDirection
    let category: MediaResourceStatsCategory
    
    var key: Int32 {
        switch category {
            case .generic:
                return 0 * 4 + self.connection.rawValue * 2 + self.direction.rawValue * 1
            case .image:
                return 1 * 4 + self.connection.rawValue * 2 + self.direction.rawValue * 1
            case .video:
                return 2 * 4 + self.connection.rawValue * 2 + self.direction.rawValue * 1
            case .audio:
                return 3 * 4 + self.connection.rawValue * 2 + self.direction.rawValue * 1
            case .file:
                return 4 * 4 + self.connection.rawValue * 2 + self.direction.rawValue * 1
        }
    }
}

private enum UsageCalculationResetKey: Int32 {
    case wifi = 80 //20 * 4 + 0
    case cellular = 81 //20 * 4 + 2
}

private func usageCalculationInfo(basePath: String, category: MediaResourceStatsCategory?) -> MTNetworkUsageCalculationInfo {
    let categoryValue: MediaResourceStatsCategory
    if let category = category {
        categoryValue = category
    } else {
        categoryValue = .generic
    }
    return MTNetworkUsageCalculationInfo(filePath: basePath + "/network-stats", incomingWWANKey: UsageCalculationTag(connection: .cellular, direction: .incoming, category: categoryValue).key, outgoingWWANKey: UsageCalculationTag(connection: .cellular, direction: .outgoing, category: categoryValue).key, incomingOtherKey: UsageCalculationTag(connection: .wifi, direction: .incoming, category: categoryValue).key, outgoingOtherKey: UsageCalculationTag(connection: .wifi, direction: .outgoing, category: categoryValue).key)
}

public struct NetworkUsageStatsDirectionsEntry: Equatable {
    public let incoming: Int64
    public let outgoing: Int64
    
    public static func ==(lhs: NetworkUsageStatsDirectionsEntry, rhs: NetworkUsageStatsDirectionsEntry) -> Bool {
        return lhs.incoming == rhs.incoming && lhs.outgoing == rhs.outgoing
    }
}

public struct NetworkUsageStatsConnectionsEntry: Equatable {
    public let cellular: NetworkUsageStatsDirectionsEntry
    public let wifi: NetworkUsageStatsDirectionsEntry
    
    public static func ==(lhs: NetworkUsageStatsConnectionsEntry, rhs: NetworkUsageStatsConnectionsEntry) -> Bool {
        return lhs.cellular == rhs.cellular && lhs.wifi == rhs.wifi
    }
}

public struct NetworkUsageStats: Equatable {
    public let generic: NetworkUsageStatsConnectionsEntry
    public let image: NetworkUsageStatsConnectionsEntry
    public let video: NetworkUsageStatsConnectionsEntry
    public let audio: NetworkUsageStatsConnectionsEntry
    public let file: NetworkUsageStatsConnectionsEntry
    
    public let resetWifiTimestamp: Int32
    public let resetCellularTimestamp: Int32
    
    public static func ==(lhs: NetworkUsageStats, rhs: NetworkUsageStats) -> Bool {
        return lhs.generic == rhs.generic && lhs.image == rhs.image && lhs.video == rhs.video && lhs.audio == rhs.audio && lhs.file == rhs.file && lhs.resetWifiTimestamp == rhs.resetWifiTimestamp && lhs.resetCellularTimestamp == rhs.resetCellularTimestamp
    }
}

public struct ResetNetworkUsageStats: OptionSet {
    public var rawValue: Int32
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public init() {
        self.rawValue = 0
    }
    
    public static let wifi = ResetNetworkUsageStats(rawValue: 1 << 0)
    public static let cellular = ResetNetworkUsageStats(rawValue: 1 << 1)
}

func networkUsageStats(basePath: String, reset: ResetNetworkUsageStats) -> Signal<NetworkUsageStats, NoError> {
    return ((Signal<NetworkUsageStats, NoError> { subscriber in
        let info = usageCalculationInfo(basePath: basePath, category: nil)
        let manager = MTNetworkUsageManager(info: info)!
        
        let rawKeys: [UsageCalculationTag] = [
            UsageCalculationTag(connection: .cellular, direction: .incoming, category: .generic),
            UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .generic),
            UsageCalculationTag(connection: .wifi, direction: .incoming, category: .generic),
            UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .generic),
            
            UsageCalculationTag(connection: .cellular, direction: .incoming, category: .image),
            UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .image),
            UsageCalculationTag(connection: .wifi, direction: .incoming, category: .image),
            UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .image),
            
            UsageCalculationTag(connection: .cellular, direction: .incoming, category: .video),
            UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .video),
            UsageCalculationTag(connection: .wifi, direction: .incoming, category: .video),
            UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .video),
            
            UsageCalculationTag(connection: .cellular, direction: .incoming, category: .audio),
            UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .audio),
            UsageCalculationTag(connection: .wifi, direction: .incoming, category: .audio),
            UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .audio),
            
            UsageCalculationTag(connection: .cellular, direction: .incoming, category: .file),
            UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .file),
            UsageCalculationTag(connection: .wifi, direction: .incoming, category: .file),
            UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .file)
        ]
        
        var keys: [NSNumber] = rawKeys.map { $0.key as NSNumber }
        
        var resetKeys: [NSNumber] = []
        var resetAddKeys: [NSNumber: NSNumber] = [:]
        let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
        if reset.contains(.wifi) {
            resetKeys = rawKeys.filter({ $0.connection == .wifi }).map({ $0.key as NSNumber })
            resetAddKeys[UsageCalculationResetKey.wifi.rawValue as NSNumber] = Int64(timestamp) as NSNumber
        }
        if reset.contains(.cellular) {
            resetKeys = rawKeys.filter({ $0.connection == .cellular }).map({ $0.key as NSNumber })
            resetAddKeys[UsageCalculationResetKey.cellular.rawValue as NSNumber] = Int64(timestamp) as NSNumber
        }
        if !resetKeys.isEmpty {
            manager.resetKeys(resetKeys, setKeys: resetAddKeys, completion: {})
        }
        keys.append(UsageCalculationResetKey.cellular.rawValue as NSNumber)
        keys.append(UsageCalculationResetKey.wifi.rawValue as NSNumber)
        
        let disposable = manager.currentStats(forKeys: keys).start(next: { next in
            var dict: [Int32: Int64] = [:]
            for key in keys {
                dict[key.int32Value] = 0
            }
            (next as! NSDictionary).enumerateKeysAndObjects({ key, value, _ in
                dict[(key as! NSNumber).int32Value] = (value as! NSNumber).int64Value
            })
            subscriber.putNext(NetworkUsageStats(
                generic: NetworkUsageStatsConnectionsEntry(
                    cellular: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .cellular, direction: .incoming, category: .generic).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .generic).key]!),
                    wifi: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .wifi, direction: .incoming, category: .generic).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .generic).key]!)),
                image: NetworkUsageStatsConnectionsEntry(
                    cellular: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .cellular, direction: .incoming, category: .image).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .image).key]!),
                    wifi: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .wifi, direction: .incoming, category: .image).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .image).key]!)),
                video: NetworkUsageStatsConnectionsEntry(
                    cellular: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .cellular, direction: .incoming, category: .video).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .video).key]!),
                    wifi: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .wifi, direction: .incoming, category: .video).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .video).key]!)),
                audio: NetworkUsageStatsConnectionsEntry(
                    cellular: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .cellular, direction: .incoming, category: .audio).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .audio).key]!),
                    wifi: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .wifi, direction: .incoming, category: .audio).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .audio).key]!)),
                file: NetworkUsageStatsConnectionsEntry(
                    cellular: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .cellular, direction: .incoming, category: .file).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .cellular, direction: .outgoing, category: .file).key]!),
                    wifi: NetworkUsageStatsDirectionsEntry(
                        incoming: dict[UsageCalculationTag(connection: .wifi, direction: .incoming, category: .file).key]!,
                        outgoing: dict[UsageCalculationTag(connection: .wifi, direction: .outgoing, category: .file).key]!)),
                resetWifiTimestamp: Int32(dict[UsageCalculationResetKey.wifi.rawValue]!),
                resetCellularTimestamp: Int32(dict[UsageCalculationResetKey.cellular.rawValue]!)
            ))
        })!
        return ActionDisposable {
            disposable.dispose()
        }
    }) |> then(Signal<NetworkUsageStats, NoError>.complete() |> delay(5.0, queue: Queue.concurrentDefaultQueue()))) |> restart
}

public struct NetworkInitializationArguments {
    public let apiId: Int32
    public let languagesCategory: String
    
    public init(apiId: Int32, languagesCategory: String) {
        self.apiId = apiId
        self.languagesCategory = languagesCategory
    }
}

func initializedNetwork(arguments: NetworkInitializationArguments, supplementary: Bool, datacenterId: Int, keychain: Keychain, basePath: String, testingEnvironment: Bool, languageCode: String?, proxySettings: ProxySettings?) -> Signal<Network, NoError> {
    return Signal { subscriber in
        Queue.concurrentDefaultQueue().async {
            let _ = registeredLoggingFunctions
            
            let serialization = Serialization()
            
            var apiEnvironment = MTApiEnvironment()
            
            apiEnvironment.apiId = arguments.apiId
            apiEnvironment.langPack = arguments.languagesCategory
            apiEnvironment.layer = NSNumber(value: Int(serialization.currentLayer()))
            apiEnvironment.disableUpdates = supplementary
            apiEnvironment = apiEnvironment.withUpdatedLangPackCode(languageCode ?? "en")
            
            if let proxySettings = proxySettings {
                apiEnvironment = apiEnvironment.withUpdatedSocksProxySettings(MTSocksProxySettings(ip: proxySettings.host, port: UInt16(proxySettings.port), username: proxySettings.username, password: proxySettings.password))
            }
            
            let context = MTContext(serialization: serialization, apiEnvironment: apiEnvironment)!
            
            let seedAddressList: [Int: String]
            
            if testingEnvironment {
                seedAddressList = [
                    // 1: "149.154.175.10",
                    // 2: "149.154.167.40"
                    // 1: "127.0.0.1",
                    // 2: "127.0.0.1"
                    1: "47.100.25.99",
                    2: "47.100.25.99"
                  
                ]
            } else {
                seedAddressList = [
                    // 1: "149.154.175.50",
                    // 2: "149.154.167.50",
                    // 3: "149.154.175.100",
                    // 4: "149.154.167.91",
                    // 5: "149.154.171.5"
                    // 1: "127.0.0.1",
                    // 2: "127.0.0.1",
                    // 3: "127.0.0.1",
                    // 4: "127.0.0.1",
                    // 5: "127.0.0.1"
                    1: "47.100.25.99",
                    2: "47.100.25.99",
                    3: "47.100.25.99",
                    4: "47.100.25.99",
                    5: "47.100.25.99"
                ]
            }
            
            for (id, ip) in seedAddressList {
                // context.setSeedAddressSetForDatacenterWithId(id, seedAddressSet: MTDatacenterAddressSet(addressList: [MTDatacenterAddress(ip: ip, port: 443, preferForMedia: false, restrictToTcp: false, cdn: false, preferForProxy: false)]))
                context.setSeedAddressSetForDatacenterWithId(id, seedAddressSet: MTDatacenterAddressSet(addressList: [MTDatacenterAddress(ip: ip, port: 12345, preferForMedia: false, restrictToTcp: false, cdn: false, preferForProxy: false)]))
            }
            
            context.keychain = keychain
            
            /*if testingEnvironment {
                for (id, ip) in seedAddressList {
                    context.updateAddressSetForDatacenter(withId: id, addressSet: MTDatacenterAddressSet(addressList: [MTDatacenterAddress(ip: ip, port: 443, preferForMedia: false, restrictToTcp: false, cdn: false, preferForProxy: false)]), forceUpdateSchemes: true)
                }
            }*/
            
            context.setDiscoverBackupAddressListSignal(MTBackupAddressSignals.fetchBackupIps(testingEnvironment, currentContext: context))
            
            let mtProto = MTProto(context: context, datacenterId: datacenterId, usageCalculationInfo: usageCalculationInfo(basePath: basePath, category: nil))!
            //mtProto.useTempAuthKeys = true
            
            let connectionStatus = Promise<ConnectionStatus>(.waitingForNetwork)
            
            let requestService = MTRequestMessageService(context: context)!
            let connectionStatusDelegate = MTProtoConnectionStatusDelegate()
            connectionStatusDelegate.action = { [weak connectionStatus] flags in
                if flags.contains(.Connected) {
                    if !flags.intersection([.UpdatingConnectionContext, .PerformingServiceTasks]).isEmpty {
                        connectionStatus?.set(single(ConnectionStatus.updating, NoError.self))
                    } else {
                        connectionStatus?.set(single(ConnectionStatus.online, NoError.self))
                    }
                } else {
                    if !flags.contains(.NetworkAvailable) {
                        connectionStatus?.set(single(ConnectionStatus.waitingForNetwork, NoError.self))
                    } else if !flags.contains(.Connected) {
                        connectionStatus?.set(single(ConnectionStatus.connecting(toProxy: flags.contains(.HasProxy)), NoError.self))
                    } else if !flags.intersection([.UpdatingConnectionContext, .PerformingServiceTasks]).isEmpty {
                        connectionStatus?.set(single(ConnectionStatus.updating, NoError.self))
                    } else {
                        connectionStatus?.set(single(ConnectionStatus.online, NoError.self))
                    }
                }
            }
            mtProto.delegate = connectionStatusDelegate
            mtProto.add(requestService)
            
            subscriber.putNext(Network(queue: Queue(), datacenterId: datacenterId, context: context, mtProto: mtProto, requestService: requestService, connectionStatusDelegate: connectionStatusDelegate, _connectionStatus: connectionStatus, basePath: basePath))
            subscriber.putCompletion()
        }
        
        return EmptyDisposable
    }
}

private final class NetworkHelper: NSObject, MTContextChangeListener {
    private let requestPublicKeys: (Int) -> Signal<NSArray, NoError>
    
    init(requestPublicKeys: @escaping (Int) -> Signal<NSArray, NoError>) {
        self.requestPublicKeys = requestPublicKeys
    }
    
    func fetchContextDatacenterPublicKeys(_ context: MTContext!, datacenterId: Int) -> MTSignal! {
        return MTSignal { subscriber in
            let disposable = self.requestPublicKeys(datacenterId).start(next: { next in
                subscriber?.putNext(next)
                subscriber?.putCompletion()
            })
            
            return MTBlockDisposable(block: {
                disposable.dispose()
            })
        }
    }
}

public final class Network: NSObject, MTRequestMessageServiceDelegate {
    private let queue: Queue
    let datacenterId: Int
    let context: MTContext
    let mtProto: MTProto
    let requestService: MTRequestMessageService
    let basePath: String
    private let connectionStatusDelegate: MTProtoConnectionStatusDelegate
    
    private let _connectionStatus: Promise<ConnectionStatus>
    public var connectionStatus: Signal<ConnectionStatus, NoError> {
        return self._connectionStatus.get() |> distinctUntilChanged
    }
    
    public let shouldKeepConnection = Promise<Bool>(false)
    private let shouldKeepConnectionDisposable = MetaDisposable()
    
    var loggedOut: (() -> Void)?
    
    fileprivate init(queue: Queue, datacenterId: Int, context: MTContext, mtProto: MTProto, requestService: MTRequestMessageService, connectionStatusDelegate: MTProtoConnectionStatusDelegate, _connectionStatus: Promise<ConnectionStatus>, basePath: String) {
        self.queue = queue
        self.datacenterId = datacenterId
        self.context = context
        self.mtProto = mtProto
        self.requestService = requestService
        self.connectionStatusDelegate = connectionStatusDelegate
        self._connectionStatus = _connectionStatus
        self.basePath = basePath
        
        super.init()
        
        context.add(NetworkHelper(requestPublicKeys: { [weak self] id in
            if let strongSelf = self {
                return strongSelf.request(Api.functions.help.getCdnConfig())
                    |> map { Optional($0) }
                    |> `catch` { _ -> Signal<Api.CdnConfig?, NoError> in
                        return .single(nil)
                    }
                    |> map { result -> NSArray in
                        let array = NSMutableArray()
                        if let result = result {
                            switch result {
                                case let .cdnConfig(publicKeys):
                                    for key in publicKeys {
                                        switch key {
                                            case let .cdnPublicKey(dcId, publicKey):
                                                if id == Int(dcId) {
                                                    let dict = NSMutableDictionary()
                                                    dict["key"] = publicKey
                                                    dict["fingerprint"] = MTRsaFingerprint(publicKey)
                                                    array.add(dict)
                                                }
                                        }
                                    }
                            }
                        }
                        return array
                    }
            } else {
                return .never()
            }
        }))
        requestService.delegate = self
        
        let shouldKeepConnectionSignal = self.shouldKeepConnection.get()
            |> distinctUntilChanged |> deliverOn(queue)
        self.shouldKeepConnectionDisposable.set(shouldKeepConnectionSignal.start(next: { [weak self] value in
            if let strongSelf = self {
                if value {
                    Logger.shared.log("Network", "Resume network connection")
                    strongSelf.mtProto.resume()
                } else {
                    Logger.shared.log("Network", "Pause network connection")
                    strongSelf.mtProto.pause()
                }
            }
        }))
    }
    
    deinit {
        self.shouldKeepConnectionDisposable.dispose()
    }
    
    public var globalTime:TimeInterval {
        return context.globalTime()
    }
    
    public func requestMessageServiceAuthorizationRequired(_ requestMessageService: MTRequestMessageService!) {
        self.loggedOut?()
    }
    
    func download(datacenterId: Int, isCdn: Bool = false, tag: MediaResourceFetchTag?) -> Signal<Download, NoError> {
        return Signal { [weak self] subscriber in
            if let strongSelf = self {
                subscriber.putNext(Download(queue: strongSelf.queue, datacenterId: datacenterId, isCdn: isCdn, context: strongSelf.context, masterDatacenterId: strongSelf.datacenterId, usageInfo: usageCalculationInfo(basePath: strongSelf.basePath, category: (tag as? TelegramMediaResourceFetchTag)?.statsCategory), shouldKeepConnection: strongSelf.shouldKeepConnection.get()))
            }
            subscriber.putCompletion()
            
            return ActionDisposable {
                
            }
        }
    }
    
    public func getApproximateRemoteTimestamp() -> Int32 {
        return Int32(self.context.globalTime())
    }
    
    public func request<T>(_ data: (CustomStringConvertible, Buffer, (Buffer) -> T?), tag: NetworkRequestDependencyTag? = nil, automaticFloodWait: Bool = true) -> Signal<T, MTRpcError> {
        let requestService = self.requestService
        return Signal { subscriber in
            let request = MTRequest()
            
            request.setPayload(data.1.makeData() as Data!, metadata: WrappedRequestMetadata(metadata: data.0, tag: tag), responseParser: { response in
                if let result = data.2(Buffer(data: response)) {
                    return BoxedMessage(result)
                }
                return nil
            })
            
            request.dependsOnPasswordEntry = false
            
            request.shouldContinueExecutionWithErrorContext = { errorContext in
                guard let errorContext = errorContext else {
                    return true
                }
                if errorContext.floodWaitSeconds > 0 && !automaticFloodWait {
                    return false
                }
                return true
            }
            
            request.completed = { (boxedResponse, timestamp, error) -> () in
                if let error = error {
                    subscriber.putError(error)
                } else {
                    if let result = (boxedResponse as! BoxedMessage).body as? T {
                        subscriber.putNext(result)
                        subscriber.putCompletion()
                    }
                    else {
                        subscriber.putError(MTRpcError(errorCode: 500, errorDescription: "TL_VERIFICATION_ERROR"))
                    }
                }
            }
            
            if let tag = tag {
                request.shouldDependOnRequest = { other in
                    if let other = other, let metadata = other.metadata as? WrappedRequestMetadata, let otherTag = metadata.tag {
                        return tag.shouldDependOn(other: otherTag)
                    }
                    return false
                }
            }
            
            let internalId: Any! = request.internalId
            
            requestService.add(request)
            
            return ActionDisposable { [weak requestService] in
                requestService?.removeRequest(byInternalId: internalId)
            }
        }
    }
}

public func retryRequest<T>(signal: Signal<T, MTRpcError>) -> Signal<T, NoError> {
    return signal |> retry(0.2, maxDelay: 5.0, onQueue: Queue.concurrentDefaultQueue())
}

class Keychain: NSObject, MTKeychain {
    let get: (String) -> Data?
    let set: (String, Data) -> Void
    let remove: (String) -> Void
    
    init(get: @escaping (String) -> Data?, set: @escaping (String, Data) -> Void, remove: @escaping (String) -> Void) {
        self.get = get
        self.set = set
        self.remove = remove
    }
    
    func setObject(_ object: Any!, forKey aKey: String!, group: String!) {
        let data = NSKeyedArchiver.archivedData(withRootObject: object)
        self.set(group + ":" + aKey, data)
    }
    
    func object(forKey aKey: String!, group: String!) -> Any! {
        if let data = self.get(group + ":" + aKey) {
            return NSKeyedUnarchiver.unarchiveObject(with: data as Data)
        }
        return nil
    }
    
    func removeObject(forKey aKey: String!, group: String!) {
        self.remove(group + ":" + aKey)
    }
    
    func dropGroup(_ group: String!) {
        
    }
}
