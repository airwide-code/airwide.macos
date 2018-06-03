import Foundation
#if os(macOS)
    import PostboxMac
#else
    import Postbox
#endif

private let typeFileName: Int32 = 0
private let typeSticker: Int32 = 1
private let typeImageSize: Int32 = 2
private let typeAnimated: Int32 = 3
private let typeVideo: Int32 = 4
private let typeAudio: Int32 = 5
private let typeHasLinkedStickers: Int32 = 6

public enum StickerPackReference: PostboxCoding, Equatable {
    case id(id: Int64, accessHash: Int64)
    case name(String)
    
    public init(decoder: PostboxDecoder) {
        switch decoder.decodeInt32ForKey("r", orElse: 0) {
            case 0:
                self = .id(id: decoder.decodeInt64ForKey("i", orElse: 0), accessHash: decoder.decodeInt64ForKey("h", orElse: 0))
            case 1:
                self = .name(decoder.decodeStringForKey("n", orElse: ""))
            default:
                self = .name("")
                assertionFailure()
        }
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        switch self {
            case let .id(id, accessHash):
                encoder.encodeInt32(0, forKey: "r")
                encoder.encodeInt64(id, forKey: "i")
                encoder.encodeInt64(accessHash, forKey: "h")
            case let .name(name):
                encoder.encodeInt32(1, forKey: "r")
                encoder.encodeString(name, forKey: "n")
        }
    }
    
    public static func ==(lhs: StickerPackReference, rhs: StickerPackReference) -> Bool {
        switch lhs {
            case let .id(id, accessHash):
                if case .id(id, accessHash) = rhs {
                    return true
                } else {
                    return false
                }
            case let .name(name):
                if case .name(name) = rhs {
                    return true
                } else {
                    return false
                }
        }
    }
}

public struct TelegramMediaVideoFlags: OptionSet {
    public var rawValue: Int32
    
    public init() {
        self.rawValue = 0
    }
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public static let instantRoundVideo = TelegramMediaVideoFlags(rawValue: 1 << 0)
}

public struct StickerMaskCoords: PostboxCoding {
    public let n: Int32
    public let x: Double
    public let y: Double
    public let zoom: Double
    
    public init(n: Int32, x: Double, y: Double, zoom: Double) {
        self.n = n
        self.x = x
        self.y = y
        self.zoom = zoom
    }
    
    public init(decoder: PostboxDecoder) {
        self.n = decoder.decodeInt32ForKey("n", orElse: 0)
        self.x = decoder.decodeDoubleForKey("x", orElse: 0.0)
        self.y = decoder.decodeDoubleForKey("y", orElse: 0.0)
        self.zoom = decoder.decodeDoubleForKey("z", orElse: 0.0)
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.n, forKey: "n")
        encoder.encodeDouble(self.x, forKey: "x")
        encoder.encodeDouble(self.y, forKey: "y")
        encoder.encodeDouble(self.zoom, forKey: "z")
    }
}

public enum TelegramMediaFileAttribute: PostboxCoding {
    case FileName(fileName: String)
    case Sticker(displayText: String, packReference: StickerPackReference?, maskData: StickerMaskCoords?)
    case ImageSize(size: CGSize)
    case Animated
    case Video(duration: Int, size: CGSize, flags: TelegramMediaVideoFlags)
    case Audio(isVoice: Bool, duration: Int, title: String?, performer: String?, waveform: MemoryBuffer?)
    case HasLinkedStickers
    
    public init(decoder: PostboxDecoder) {
        let type: Int32 = decoder.decodeInt32ForKey("t", orElse: 0)
        switch type {
            case typeFileName:
                self = .FileName(fileName: decoder.decodeStringForKey("fn", orElse: ""))
            case typeSticker:
                self = .Sticker(displayText: decoder.decodeStringForKey("dt", orElse: ""), packReference: decoder.decodeObjectForKey("pr", decoder: { StickerPackReference(decoder: $0) }) as? StickerPackReference, maskData: decoder.decodeObjectForKey("mc", decoder: { StickerMaskCoords(decoder: $0) }) as? StickerMaskCoords)
            case typeImageSize:
                self = .ImageSize(size: CGSize(width: CGFloat(decoder.decodeInt32ForKey("w", orElse: 0)), height: CGFloat(decoder.decodeInt32ForKey("h", orElse: 0))))
            case typeAnimated:
                self = .Animated
            case typeVideo:
                self = .Video(duration: Int(decoder.decodeInt32ForKey("du", orElse: 0)), size: CGSize(width: CGFloat(decoder.decodeInt32ForKey("w", orElse: 0)), height: CGFloat(decoder.decodeInt32ForKey("h", orElse: 0))), flags: TelegramMediaVideoFlags(rawValue: decoder.decodeInt32ForKey("f", orElse: 0)))
            case typeAudio:
                let waveformBuffer = decoder.decodeBytesForKeyNoCopy("wf")
                var waveform: MemoryBuffer?
                if let waveformBuffer = waveformBuffer {
                    waveform = MemoryBuffer(copyOf: waveformBuffer)
                }
                self = .Audio(isVoice: decoder.decodeInt32ForKey("iv", orElse: 0) != 0, duration: Int(decoder.decodeInt32ForKey("du", orElse: 0)), title: decoder.decodeOptionalStringForKey("ti"), performer: decoder.decodeOptionalStringForKey("pe"), waveform: waveform)
            case typeHasLinkedStickers:
                self = .HasLinkedStickers
            default:
                preconditionFailure()
        }
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        switch self {
            case let .FileName(fileName):
                encoder.encodeInt32(typeFileName, forKey: "t")
                encoder.encodeString(fileName, forKey: "fn")
            case let .Sticker(displayText, packReference, maskCoords):
                encoder.encodeInt32(typeSticker, forKey: "t")
                encoder.encodeString(displayText, forKey: "dt")
                if let packReference = packReference {
                    encoder.encodeObject(packReference, forKey: "pr")
                } else {
                    encoder.encodeNil(forKey: "pr")
                }
                if let maskCoords = maskCoords {
                    encoder.encodeObject(maskCoords, forKey: "mc")
                } else {
                    encoder.encodeNil(forKey: "mc")
                }
            case let .ImageSize(size):
                encoder.encodeInt32(typeImageSize, forKey: "t")
                encoder.encodeInt32(Int32(size.width), forKey: "w")
                encoder.encodeInt32(Int32(size.height), forKey: "h")
            case .Animated:
                encoder.encodeInt32(typeAnimated, forKey: "t")
            case let .Video(duration, size, flags):
                encoder.encodeInt32(typeVideo, forKey: "t")
                encoder.encodeInt32(Int32(duration), forKey: "du")
                encoder.encodeInt32(Int32(size.width), forKey: "w")
                encoder.encodeInt32(Int32(size.height), forKey: "h")
                encoder.encodeInt32(flags.rawValue, forKey: "f")
            case let .Audio(isVoice, duration, title, performer, waveform):
                encoder.encodeInt32(typeAudio, forKey: "t")
                encoder.encodeInt32(isVoice ? 1 : 0, forKey: "iv")
                encoder.encodeInt32(Int32(duration), forKey: "du")
                if let title = title {
                    encoder.encodeString(title, forKey: "ti")
                }
                if let performer = performer {
                    encoder.encodeString(performer, forKey: "pe")
                }
                if let waveform = waveform {
                    encoder.encodeBytes(waveform, forKey: "wf")
                }
            case .HasLinkedStickers:
                encoder.encodeInt32(typeHasLinkedStickers, forKey: "t")
        }
    }
}

func dimensionsForFileAttributes(_ attributes: [TelegramMediaFileAttribute]) -> CGSize? {
    for attribute in attributes {
        switch attribute {
            case let .Video(_, size, _):
                return size
            case let .ImageSize(size):
                return size
            default:
                break
        }
    }
    return nil
}

func durationForFileAttributes(_ attributes: [TelegramMediaFileAttribute]) -> Int32? {
    for attribute in attributes {
        switch attribute {
            case let .Video(duration, _, _):
                return Int32(duration)
            case let .Audio(_, duration, _, _, _):
                return Int32(duration)
            default:
                break
        }
    }
    return nil
}

public final class TelegramMediaFile: Media, Equatable {
    public let fileId: MediaId
    public let resource: TelegramMediaResource
    public let previewRepresentations: [TelegramMediaImageRepresentation]
    public let mimeType: String
    public let size: Int?
    public let attributes: [TelegramMediaFileAttribute]
    public let peerIds: [PeerId] = []
    
    public var id: MediaId? {
        return self.fileId
    }
    
    public init(fileId: MediaId, resource: TelegramMediaResource, previewRepresentations: [TelegramMediaImageRepresentation], mimeType: String, size: Int?, attributes: [TelegramMediaFileAttribute]) {
        self.fileId = fileId
        self.resource = resource
        self.previewRepresentations = previewRepresentations
        self.mimeType = mimeType
        self.size = size
        self.attributes = attributes
    }
    
    public init(decoder: PostboxDecoder) {
        self.fileId = MediaId(decoder.decodeBytesForKeyNoCopy("i")!)
        self.resource = decoder.decodeObjectForKey("r") as! TelegramMediaResource
        self.previewRepresentations = decoder.decodeObjectArrayForKey("pr")
        self.mimeType = decoder.decodeStringForKey("mt", orElse: "")
        if let size = decoder.decodeOptionalInt32ForKey("s") {
            self.size = Int(size)
        } else {
            self.size = nil
        }
        self.attributes = decoder.decodeObjectArrayForKey("at")
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        let buffer = WriteBuffer()
        self.fileId.encodeToBuffer(buffer)
        encoder.encodeBytes(buffer, forKey: "i")
        encoder.encodeObject(self.resource, forKey: "r")
        encoder.encodeObjectArray(self.previewRepresentations, forKey: "pr")
        encoder.encodeString(self.mimeType, forKey: "mt")
        if let size = self.size {
            encoder.encodeInt32(Int32(size), forKey: "s")
        } else {
            encoder.encodeNil(forKey: "s")
        }
        encoder.encodeObjectArray(self.attributes, forKey: "at")
    }
    
    public var fileName: String? {
        get {
            for attribute in self.attributes {
                switch attribute {
                    case let .FileName(fileName):
                        return fileName
                    case _:
                        break
                }
            }
            return nil
        }
    }
    
    public var isSticker: Bool {
        for attribute in self.attributes {
            if case .Sticker = attribute {
                return true
            }
        }
        return false
    }
    
    public var isVideo: Bool {
        for attribute in self.attributes {
            if case .Video = attribute {
                return true
            }
        }
        return false
    }
    
    public var isInstantVideo: Bool {
        for attribute in self.attributes {
            if case .Video(_, _, let flags) = attribute {
                return flags.contains(.instantRoundVideo)
            }
        }
        return false
    }
    
    public var isAnimated: Bool {
        for attribute in self.attributes {
            if case .Animated = attribute {
                return true
            }
        }
        return false
    }
    
    public var isMusic: Bool {
        for attribute in self.attributes {
            if case .Audio(false, _, _, _, _) = attribute {
                return true
            }
        }
        return false
    }
    
    public var isVoice: Bool {
        for attribute in self.attributes {
            if case .Audio(true, _, _, _, _) = attribute {
                return true
            }
        }
        return false
    }
    
    public var dimensions: CGSize? {
        return dimensionsForFileAttributes(self.attributes)
    }
    
    public var duration: Int32? {
        return durationForFileAttributes(self.attributes)
    }
    
    public func isEqual(_ other: Media) -> Bool {
        guard let other = other as? TelegramMediaFile else {
            return false
        }
        
        if self.fileId != other.fileId {
            return false
        }
        
        if !self.resource.isEqual(to: other.resource) {
            return false
        }
        
        if self.previewRepresentations != other.previewRepresentations {
            return false
        }
        
        if self.size != other.size {
            return false
        }
        
        if self.mimeType != other.mimeType {
            return false
        }
        
        /*if self.attributes != other.attributes {
            return false
        }*/
        
        return true
    }
    
    public func withUpdatedSize(_ size: Int?) -> TelegramMediaFile {
        return TelegramMediaFile(fileId: self.fileId, resource: self.resource, previewRepresentations: self.previewRepresentations, mimeType: self.mimeType, size: size, attributes: self.attributes)
    }
    
    public func withUpdatedPreviewRepresentations(_ previewRepresentations: [TelegramMediaImageRepresentation]) -> TelegramMediaFile {
        return TelegramMediaFile(fileId: self.fileId, resource: self.resource, previewRepresentations: previewRepresentations, mimeType: self.mimeType, size: self.size, attributes: self.attributes)
    }
}

public func ==(lhs: TelegramMediaFile, rhs: TelegramMediaFile) -> Bool {
    return lhs.isEqual(rhs)
}

extension StickerPackReference {
    init?(apiInputSet: Api.InputStickerSet) {
        switch apiInputSet {
            case .inputStickerSetEmpty:
                return nil
            case let .inputStickerSetID(id, accessHash):
                self = .id(id: id, accessHash: accessHash)
            case let .inputStickerSetShortName(shortName):
                self = .name(shortName)
        }
    }
}

extension StickerMaskCoords {
    init(apiMaskCoords: Api.MaskCoords) {
        switch apiMaskCoords {
            case let .maskCoords(n, x, y, zoom):
                self.init(n: n, x: x, y: y, zoom: zoom)
        }
    }
}

public func telegramMediaFileAttributesFromApiAttributes(_ attributes: [Api.DocumentAttribute]) -> [TelegramMediaFileAttribute] {
    var result: [TelegramMediaFileAttribute] = []
    for attribute in attributes {
        switch attribute {
            case let .documentAttributeFilename(fileName):
                result.append(.FileName(fileName: fileName))
            case let .documentAttributeSticker(_, alt, stickerSet, maskCoords):
                result.append(.Sticker(displayText: alt, packReference: StickerPackReference(apiInputSet: stickerSet), maskData: maskCoords.flatMap(StickerMaskCoords.init)))
            case .documentAttributeHasStickers:
                result.append(.HasLinkedStickers)
            case let .documentAttributeImageSize(w, h):
                result.append(.ImageSize(size: CGSize(width: CGFloat(w), height: CGFloat(h))))
            case .documentAttributeAnimated:
                result.append(.Animated)
            case let .documentAttributeVideo(flags, duration, w, h):
                var videoFlags = TelegramMediaVideoFlags()
                if (flags & (1 << 0)) != 0 {
                    videoFlags.insert(.instantRoundVideo)
                }
                result.append(.Video(duration: Int(duration), size: CGSize(width: CGFloat(w), height: CGFloat(h)), flags: videoFlags))
            case let .documentAttributeAudio(flags, duration, title, performer, waveform):
                let isVoice = (flags & (1 << 10)) != 0
                var waveformBuffer: MemoryBuffer?
                if let waveform = waveform {
                    let memory = malloc(waveform.size)!
                    memcpy(memory, waveform.data, waveform.size)
                    waveformBuffer = MemoryBuffer(memory: memory, capacity: waveform.size, length: waveform.size, freeWhenDone: true)
                }
                result.append(.Audio(isVoice: isVoice, duration: Int(duration), title: title, performer: performer, waveform: waveformBuffer))
        }
    }
    return result
}

public func telegramMediaFileFromApiDocument(_ document: Api.Document) -> TelegramMediaFile? {
    switch document {
        case let .document(id, accessHash, _, mimeType, size, thumb, dcId, _, attributes):
            return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: id), resource: CloudDocumentMediaResource(datacenterId: Int(dcId), fileId: id, accessHash: accessHash, size: Int(size)), previewRepresentations: telegramMediaImageRepresentationsFromApiSizes([thumb]), mimeType: mimeType, size: Int(size), attributes: telegramMediaFileAttributesFromApiAttributes(attributes))
        case .documentEmpty:
            return nil
    }
}
