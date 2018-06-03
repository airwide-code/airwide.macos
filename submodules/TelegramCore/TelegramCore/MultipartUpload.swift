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

#if os(macOS)
    private typealias SignalKitTimer = SwiftSignalKitMac.Timer
#else
    private typealias SignalKitTimer = SwiftSignalKit.Timer
#endif

public final class SecretFileEncryptionKey: PostboxCoding, Equatable {
    public let aesKey: Data
    public let aesIv: Data
    
    public init(aesKey: Data, aesIv: Data) {
        self.aesKey = aesKey
        self.aesIv = aesIv
    }
    
    public init(decoder: PostboxDecoder) {
        self.aesKey = decoder.decodeBytesForKey("k")!.makeData()
        self.aesIv = decoder.decodeBytesForKey("i")!.makeData()
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeBytes(MemoryBuffer(data: self.aesKey), forKey: "k")
        encoder.encodeBytes(MemoryBuffer(data: self.aesIv), forKey: "i")
    }
    
    public static func ==(lhs: SecretFileEncryptionKey, rhs: SecretFileEncryptionKey) -> Bool {
        return lhs.aesKey == rhs.aesKey && lhs.aesIv == rhs.aesIv
    }
}

private struct UploadPart {
    let fileId: Int64
    let index: Int
    let data: Data
    let bigTotalParts: Int?
}

private func md5(_ data : Data) -> Data {
    var res = Data()
    res.count = Int(CC_MD5_DIGEST_LENGTH)
    res.withUnsafeMutableBytes { mutableBytes -> Void in
        data.withUnsafeBytes { bytes -> Void in
            CC_MD5(bytes, CC_LONG(data.count), mutableBytes)
        }
    }
    return res
}

private final class MultipartUploadState {
    let aesKey: Data
    var aesIv: Data
    var effectiveSize: Int = 0
    
    init(encryptionKey: SecretFileEncryptionKey?) {
        if let encryptionKey = encryptionKey {
            self.aesKey = encryptionKey.aesKey
            self.aesIv = encryptionKey.aesIv
        } else {
            self.aesKey = Data()
            self.aesIv = Data()
        }
    }
    
    func transform(data: Data) -> Data {
        if self.aesKey.count != 0 {
            var encryptedData = data
            var paddingSize = 0
            while (encryptedData.count + paddingSize) % 16 != 0 {
                paddingSize += 1
            }
            if paddingSize != 0 {
                encryptedData.count = encryptedData.count + paddingSize
            }
            encryptedData.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                if paddingSize != 0 {
                    arc4random_buf(bytes.advanced(by: encryptedData.count - paddingSize), paddingSize)
                }
                self.aesIv.withUnsafeMutableBytes { (iv: UnsafeMutablePointer<UInt8>) -> Void in
                    MTAesEncryptBytesInplaceAndModifyIv(bytes, encryptedData.count, self.aesKey, iv)
                }
            }
            effectiveSize += encryptedData.count
            return encryptedData
        } else {
            effectiveSize += data.count
            return data
        }
    }
    
    func finalize() -> Int {
        return self.effectiveSize
    }
}

private struct MultipartIntermediateResult {
    let id: Int64
    let partCount: Int32
    let md5Digest: String
    let size: Int32
    let bigTotalParts: Int?
}

private enum MultipartUploadData {
    case resourceData(MediaResourceData)
    case data(Data)
    
    var size: Int {
        switch self {
            case let .resourceData(data):
                return data.size
            case let .data(data):
                return data.count
        }
    }
    var complete: Bool {
        switch self {
            case let .resourceData(data):
                return data.complete
            case .data:
                return true
        }
    }
}

private final class MultipartUploadManager {
    let parallelParts: Int = 3
    let defaultPartSize: Int
    let bigTotalParts: Int?
    
    let queue = Queue()
    let fileId: Int64
    
    let dataSignal: Signal<MultipartUploadData, NoError>
    
    var committedOffset: Int
    let uploadPart: (UploadPart) -> Signal<Void, NoError>
    let progress: (Float) -> Void
    let completed: (MultipartIntermediateResult?) -> Void
    
    var uploadingParts: [Int: (Int, Disposable)] = [:]
    var uploadedParts: [Int: Int] = [:]
    
    let dataDisposable = MetaDisposable()
    var resourceData: MultipartUploadData?
    
    var headerPartReady: Bool
    
    let state: MultipartUploadState
    
    init(headerSize: Int32, data: Signal<MultipartUploadData, NoError>, encryptionKey: SecretFileEncryptionKey?, hintFileSize: Int?, uploadPart: @escaping (UploadPart) -> Signal<Void, NoError>, progress: @escaping (Float) -> Void, completed: @escaping (MultipartIntermediateResult?) -> Void) {
        self.dataSignal = data
        
        var fileId: Int64 = 0
        arc4random_buf(&fileId, 8)
        self.fileId = fileId
        
        self.state = MultipartUploadState(encryptionKey: encryptionKey)
        
        self.committedOffset = 0
        self.uploadPart = uploadPart
        self.progress = progress
        self.completed = completed
        
        self.headerPartReady = headerSize == 0
        
        if let hintFileSize = hintFileSize, hintFileSize > 5 * 1024 * 1024 {
            self.defaultPartSize = 512 * 1024
            self.bigTotalParts = (hintFileSize / self.defaultPartSize) + (hintFileSize % self.defaultPartSize == 0 ? 0 : 1)
        } else {
            if self.headerPartReady {
                self.defaultPartSize = 32 * 1024
                self.bigTotalParts = nil
            } else {
                self.defaultPartSize = 32 * 1024
                self.bigTotalParts = nil
                //self.defaultPartSize = 128 * 1024
                //self.bigTotalParts = -1
            }
        }
        
        if self.headerPartReady {
            self.committedOffset = 0
        } else {
            self.committedOffset = self.defaultPartSize
            self.state.effectiveSize = self.defaultPartSize
        }
    }
    
    func start() {
        self.queue.async {
            self.dataDisposable.set((self.dataSignal |> deliverOn(self.queue)).start(next: { [weak self] data in
                if let strongSelf = self {
                    strongSelf.resourceData = data
                    strongSelf.checkState()
                }
            }))
        }
    }
    
    func cancel() {
        self.queue.async {
            for (_, (_, disposable)) in self.uploadingParts {
                disposable.dispose()
            }
        }
    }
    
    func checkState() {
        var updatedCommittedOffset = false
        for offset in self.uploadedParts.keys.sorted() {
            if offset == self.committedOffset {
                let partSize = self.uploadedParts[offset]!
                self.committedOffset += partSize
                updatedCommittedOffset = true
                let _ = self.uploadedParts.removeValue(forKey: offset)
            }
        }
        if updatedCommittedOffset {
            if let resourceData = self.resourceData, resourceData.complete && resourceData.size != 0 {
                self.progress(Float(self.committedOffset) / Float(resourceData.size))
            }
        }
        
        if let resourceData = self.resourceData, resourceData.complete, self.committedOffset >= resourceData.size {
            if self.headerPartReady {
                let effectiveSize = self.state.finalize()
                let effectivePartCount = Int32(effectiveSize / self.defaultPartSize + (effectiveSize % self.defaultPartSize == 0 ? 0 : 1))
                self.completed(MultipartIntermediateResult(id: self.fileId, partCount: effectivePartCount, md5Digest: "", size: Int32(resourceData.size), bigTotalParts: self.bigTotalParts))
            } else {
                let partOffset = 0
                let partSize = min(resourceData.size - partOffset, self.defaultPartSize)
                let partIndex = partOffset / self.defaultPartSize
                let fileData: Data?
                switch resourceData {
                    case let .resourceData(data):
                        fileData = try? Data(contentsOf: URL(fileURLWithPath: data.path), options: [.alwaysMapped])
                    case let .data(data):
                        fileData = data
                }
                let partData = fileData!.subdata(in: partOffset ..< (partOffset + partSize))
                var currentBigTotalParts = self.bigTotalParts
                if let _ = self.bigTotalParts {
                    currentBigTotalParts = (resourceData.size / self.defaultPartSize) + (resourceData.size % self.defaultPartSize == 0 ? 0 : 1)
                }
                let part = self.uploadPart(UploadPart(fileId: self.fileId, index: partIndex, data: partData, bigTotalParts: currentBigTotalParts))
                    |> deliverOn(self.queue)
                self.uploadingParts[0] = (partSize, part.start(completed: { [weak self] in
                    if let strongSelf = self {
                        let _ = strongSelf.uploadingParts.removeValue(forKey: 0)
                        strongSelf.headerPartReady = true
                        strongSelf.checkState()
                    }
                }))
            }
        } else {
            while uploadingParts.count < self.parallelParts {
                var nextOffset = self.committedOffset
                for (offset, (size, _)) in self.uploadingParts {
                    nextOffset = max(nextOffset, offset + size)
                }
                for (offset, partSize) in self.uploadedParts {
                    nextOffset = max(nextOffset, offset + partSize)
                }
                
                if let resourceData = self.resourceData {
                    let partOffset = nextOffset
                    let partSize = min(resourceData.size - partOffset, self.defaultPartSize)
                    
                    if nextOffset < resourceData.size && partSize > 0 && (resourceData.complete || partSize == self.defaultPartSize) {
                        let partIndex = partOffset / self.defaultPartSize
                        let fileData: Data?
                        switch resourceData {
                            case let .resourceData(data):
                                fileData = try? Data(contentsOf: URL(fileURLWithPath: data.path), options: [.alwaysMapped])
                            case let .data(data):
                                fileData = data
                        }
                        if let fileData = fileData {
                            let partData = self.state.transform(data: fileData.subdata(in: partOffset ..< (partOffset + partSize)))
                            var currentBigTotalParts = self.bigTotalParts
                            if let _ = self.bigTotalParts, resourceData.complete && partOffset + partSize == resourceData.size {
                                currentBigTotalParts = (resourceData.size / self.defaultPartSize) + (resourceData.size % self.defaultPartSize == 0 ? 0 : 1)
                            }
                            let part = self.uploadPart(UploadPart(fileId: self.fileId, index: partIndex, data: partData, bigTotalParts: currentBigTotalParts))
                                |> deliverOn(self.queue)
                            self.uploadingParts[nextOffset] = (partSize, part.start(completed: { [weak self] in
                                if let strongSelf = self {
                                    let _ = strongSelf.uploadingParts.removeValue(forKey: nextOffset)
                                    strongSelf.uploadedParts[partOffset] = partSize
                                    strongSelf.checkState()
                                }
                            }))
                        } else {
                            self.completed(nil)
                        }
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }
    }
}

enum MultipartUploadResult {
    case progress(Float)
    case inputFile(Api.InputFile)
    case inputSecretFile(Api.InputEncryptedFile, Int32, SecretFileEncryptionKey)
}

public enum MultipartUploadSource {
    case resource(MediaResource)
    case data(Data)
}

enum MultipartUploadError {
    case generic
}

func multipartUpload(network: Network, postbox: Postbox, source: MultipartUploadSource, encrypt: Bool, tag: MediaResourceFetchTag?, hintFileSize: Int? = nil) -> Signal<MultipartUploadResult, MultipartUploadError> {
    return network.download(datacenterId: network.datacenterId, tag: tag)
        |> mapToSignalPromotingError { download -> Signal<MultipartUploadResult, MultipartUploadError> in
            return Signal { subscriber in
                var encryptionKey: SecretFileEncryptionKey?
                if encrypt {
                    var aesKey = Data()
                    aesKey.count = 32
                    var aesIv = Data()
                    aesIv.count = 32
                    aesKey.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                        arc4random_buf(bytes, 32)
                    }
                    aesIv.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                        arc4random_buf(bytes, 32)
                    }
                    encryptionKey = SecretFileEncryptionKey(aesKey: aesKey, aesIv: aesIv)
                }
                
                let dataSignal: Signal<MultipartUploadData, NoError>
                let headerSize: Int32
                let fetchedResource: Signal<Void, NoError>
                switch source {
                    case let .resource(resource):
                        dataSignal = postbox.mediaBox.resourceData(resource, option: .incremental(waitUntilFetchStatus: true)) |> map { MultipartUploadData.resourceData($0) }
                        headerSize = resource.headerSize
                        fetchedResource = postbox.mediaBox.fetchedResource(resource, tag: tag) |> map {_ in}
                    case let .data(data):
                        dataSignal = .single(.data(data))
                        headerSize = 0
                        fetchedResource = .complete()
                }
                
                let manager = MultipartUploadManager(headerSize: headerSize, data: dataSignal, encryptionKey: encryptionKey, hintFileSize: hintFileSize, uploadPart: { part in
                    return download.uploadPart(fileId: part.fileId, index: part.index, data: part.data, bigTotalParts: part.bigTotalParts)
                }, progress: { progress in
                    subscriber.putNext(.progress(progress))
                }, completed: { result in
                    if let result = result {
                        if let encryptionKey = encryptionKey {
                            let keyDigest = md5(encryptionKey.aesKey + encryptionKey.aesIv)
                            var fingerprint: Int32 = 0
                            keyDigest.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
                                withUnsafeMutableBytes(of: &fingerprint, { ptr -> Void in
                                    let uintPtr = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                                    uintPtr[0] = bytes[0] ^ bytes[4]
                                    uintPtr[1] = bytes[1] ^ bytes[5]
                                    uintPtr[2] = bytes[2] ^ bytes[6]
                                    uintPtr[3] = bytes[3] ^ bytes[7]
                                })
                            }
                            if let _ = result.bigTotalParts {
                                let inputFile = Api.InputEncryptedFile.inputEncryptedFileBigUploaded(id: result.id, parts: result.partCount, keyFingerprint: fingerprint)
                                subscriber.putNext(.inputSecretFile(inputFile, result.size, encryptionKey))
                            } else {
                                let inputFile = Api.InputEncryptedFile.inputEncryptedFileUploaded(id: result.id, parts: result.partCount, md5Checksum: result.md5Digest, keyFingerprint: fingerprint)
                                subscriber.putNext(.inputSecretFile(inputFile, result.size, encryptionKey))
                            }
                        } else {
                            if let _ = result.bigTotalParts {
                                let inputFile = Api.InputFile.inputFileBig(id: result.id, parts: result.partCount, name: "file.jpg")
                                subscriber.putNext(.inputFile(inputFile))
                            } else {
                                let inputFile = Api.InputFile.inputFile(id: result.id, parts: result.partCount, name: "file.jpg", md5Checksum: result.md5Digest)
                                subscriber.putNext(.inputFile(inputFile))
                            }
                        }
                        subscriber.putCompletion()
                    } else {
                        subscriber.putError(.generic)
                    }
                })

                manager.start()
                
                let fetchedResourceDisposable = fetchedResource.start()
                
                return ActionDisposable {
                    manager.cancel()
                    fetchedResourceDisposable.dispose()
                }
            }
    }
}
