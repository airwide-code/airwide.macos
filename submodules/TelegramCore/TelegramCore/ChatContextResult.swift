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

public enum ChatContextResultMessage: PostboxCoding, Equatable {
    case auto(caption: String, replyMarkup: ReplyMarkupMessageAttribute?)
    case text(text: String, entities: TextEntitiesMessageAttribute?, disableUrlPreview: Bool, replyMarkup: ReplyMarkupMessageAttribute?)
    case mapLocation(media: TelegramMediaMap, replyMarkup: ReplyMarkupMessageAttribute?)
    case contact(media: TelegramMediaContact, replyMarkup: ReplyMarkupMessageAttribute?)
    
    public init(decoder: PostboxDecoder) {
        switch decoder.decodeInt32ForKey("_v", orElse: 0) {
            case 0:
                self = .auto(caption: decoder.decodeStringForKey("c", orElse: ""), replyMarkup: decoder.decodeObjectForKey("m") as? ReplyMarkupMessageAttribute)
            case 1:
                self = .text(text: decoder.decodeStringForKey("t", orElse: ""), entities: decoder.decodeObjectForKey("e") as? TextEntitiesMessageAttribute, disableUrlPreview: decoder.decodeInt32ForKey("du", orElse: 0) != 0, replyMarkup: decoder.decodeObjectForKey("m") as? ReplyMarkupMessageAttribute)
            case 2:
                self = .mapLocation(media: decoder.decodeObjectForKey("l") as! TelegramMediaMap, replyMarkup: decoder.decodeObjectForKey("m") as? ReplyMarkupMessageAttribute)
            case 3:
                self = .contact(media: decoder.decodeObjectForKey("c") as! TelegramMediaContact, replyMarkup: decoder.decodeObjectForKey("m") as? ReplyMarkupMessageAttribute)
            default:
                self = .auto(caption: "", replyMarkup: nil)
        }
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        switch self {
            case let .auto(caption, replyMarkup):
                encoder.encodeInt32(0, forKey: "_v")
                encoder.encodeString(caption, forKey: "c")
                if let replyMarkup = replyMarkup {
                    encoder.encodeObject(replyMarkup, forKey: "m")
                } else {
                    encoder.encodeNil(forKey: "m")
                }
            case let .text(text, entities, disableUrlPreview, replyMarkup):
                encoder.encodeInt32(1, forKey: "_v")
                encoder.encodeString(text, forKey: "t")
                if let entities = entities {
                    encoder.encodeObject(entities, forKey: "e")
                } else {
                    encoder.encodeNil(forKey: "e")
                }
                encoder.encodeInt32(disableUrlPreview ? 1 : 0, forKey: "du")
                if let replyMarkup = replyMarkup {
                    encoder.encodeObject(replyMarkup, forKey: "m")
                } else {
                    encoder.encodeNil(forKey: "m")
                }
            case let .mapLocation(media, replyMarkup):
                encoder.encodeInt32(2, forKey: "_v")
                encoder.encodeObject(media, forKey: "l")
                if let replyMarkup = replyMarkup {
                    encoder.encodeObject(replyMarkup, forKey: "m")
                } else {
                    encoder.encodeNil(forKey: "m")
                }
            case let .contact(media, replyMarkup):
                encoder.encodeInt32(3, forKey: "_v")
                encoder.encodeObject(media, forKey: "c")
                if let replyMarkup = replyMarkup {
                    encoder.encodeObject(replyMarkup, forKey: "m")
                } else {
                    encoder.encodeNil(forKey: "m")
                }
        }
    }
    
    public static func ==(lhs: ChatContextResultMessage, rhs: ChatContextResultMessage) -> Bool {
        switch lhs {
            case let .auto(lhsCaption, lhsReplyMarkup):
                if case let .auto(rhsCaption, rhsReplyMarkup) = rhs {
                    if lhsCaption != rhsCaption {
                        return false
                    }
                    if lhsReplyMarkup != rhsReplyMarkup {
                        return false
                    }
                    return true
                } else {
                    return false
                }
            case let .text(lhsText, lhsEntities, lhsDisableUrlPreview, lhsReplyMarkup):
                if case let .text(rhsText, rhsEntities, rhsDisableUrlPreview, rhsReplyMarkup) = rhs {
                    if lhsText != rhsText {
                        return false
                    }
                    if lhsEntities != rhsEntities {
                        return false
                    }
                    if lhsDisableUrlPreview != rhsDisableUrlPreview {
                        return false
                    }
                    if lhsReplyMarkup != rhsReplyMarkup {
                        return false
                    }
                    return true
                } else {
                    return false
                }
            case let .mapLocation(lhsMedia, lhsReplyMarkup):
                if case let .mapLocation(rhsMedia, rhsReplyMarkup) = rhs {
                    if !lhsMedia.isEqual(rhsMedia) {
                        return false
                    }
                    if lhsReplyMarkup != rhsReplyMarkup {
                        return false
                    }
                    return true
                } else {
                    return false
                }
            case let .contact(lhsMedia, lhsReplyMarkup):
                if case let .contact(rhsMedia, rhsReplyMarkup) = rhs {
                    if !lhsMedia.isEqual(rhsMedia) {
                        return false
                    }
                    if lhsReplyMarkup != rhsReplyMarkup {
                        return false
                    }
                    return true
                } else {
                    return false
                }
        }
    }
}

public enum ChatContextResult: Equatable {
    case externalReference(id: String, type: String, title: String?, description: String?, url: String?, thumbnailUrl: String?, contentUrl: String?, contentType: String?, dimensions: CGSize?, duration: Int32?, message: ChatContextResultMessage)
    case internalReference(id: String, type: String, title: String?, description: String?, image: TelegramMediaImage?, file: TelegramMediaFile?, message: ChatContextResultMessage)
    
    public var id: String {
        switch self {
            case let .externalReference(id, _, _, _, _, _, _, _, _, _, _):
                return id
            case let .internalReference(id, _, _, _, _, _, _):
                return id
        }
    }
    
    public var type: String {
        switch self {
            case let .externalReference(_, type, _, _, _, _, _, _, _, _, _):
                return type
            case let .internalReference(_, type, _, _, _, _, _):
                return type
        }
    }
    
    public var title: String? {
        switch self {
            case let .externalReference(_, _, title, _, _, _, _, _, _, _, _):
                return title
            case let .internalReference(_, _, title, _, _, _, _):
                return title
        }
    }
    
    public var description: String? {
        switch self {
            case let .externalReference(_, _, _, description, _, _, _, _, _, _, _):
                return description
            case let .internalReference(_, _, _, description, _, _, _):
                return description
        }
    }
    
    public var message: ChatContextResultMessage {
        switch self {
            case let .externalReference(_, _, _, _, _, _, _, _, _, _, message):
                return message
            case let .internalReference(_, _, _, _, _, _, message):
                return message
        }
    }
    
    public static func ==(lhs: ChatContextResult, rhs: ChatContextResult) -> Bool {
        switch lhs {
            case let .externalReference(lhsId, lhsType, lhsTitle, lhsDescription, lhsUrl, lhsThumbnailUrl, lhsContentUrl, lhsContentType, lhsDimensions, lhsDuration, lhsMessage):
                if case let .externalReference(rhsId, rhsType, rhsTitle, rhsDescription, rhsUrl, rhsThumbnailUrl, rhsContentUrl, rhsContentType, rhsDimensions, rhsDuration, rhsMessage) = rhs {
                    if lhsId != rhsId {
                        return false
                    }
                    if lhsType != rhsType {
                        return false
                    }
                    if lhsTitle != rhsTitle {
                        return false
                    }
                    if lhsDescription != rhsDescription {
                        return false
                    }
                    if lhsUrl != rhsUrl {
                        return false
                    }
                    if lhsThumbnailUrl != rhsThumbnailUrl {
                        return false
                    }
                    if lhsContentUrl != rhsContentUrl {
                        return false
                    }
                    if lhsContentType != rhsContentType {
                        return false
                    }
                    if lhsDimensions != rhsDimensions {
                        return false
                    }
                    if lhsDuration != rhsDuration {
                        return false
                    }
                    if lhsMessage != rhsMessage {
                        return false
                    }
                    return true
                } else {
                    return false
                }
            case let .internalReference(lhsId, lhsType, lhsTitle, lhsDescription, lhsImage, lhsFile, lhsMessage):
                if case let .internalReference(rhsId, rhsType, rhsTitle, rhsDescription, rhsImage, rhsFile, rhsMessage) = rhs {
                    if lhsId != rhsId {
                        return false
                    }
                    if lhsType != rhsType {
                        return false
                    }
                    if lhsTitle != rhsTitle {
                        return false
                    }
                    if lhsDescription != rhsDescription {
                        return false
                    }
                    if let lhsImage = lhsImage, let rhsImage = rhsImage {
                        if !lhsImage.isEqual(rhsImage) {
                            return false
                        }
                    } else if (lhsImage != nil) != (rhsImage != nil) {
                        return false
                    }
                    if let lhsFile = lhsFile, let rhsFile = rhsFile {
                        if !lhsFile.isEqual(rhsFile) {
                            return false
                        }
                    } else if (lhsFile != nil) != (rhsFile != nil) {
                        return false
                    }
                    if lhsMessage != rhsMessage {
                        return false
                    }
                    return true
                } else {
                    return false
                }
        }
    }
}

public enum ChatContextResultCollectionPresentation {
    case media
    case list
}

public struct ChatContextResultSwitchPeer: Equatable {
    public let text: String
    public let startParam: String
    
    public static func ==(lhs: ChatContextResultSwitchPeer, rhs: ChatContextResultSwitchPeer) -> Bool {
        return lhs.text == rhs.text && lhs.startParam == rhs.startParam
    }
}

public final class ChatContextResultCollection: Equatable {
    public let botId: PeerId
    public let queryId: Int64
    public let nextOffset: String?
    public let presentation: ChatContextResultCollectionPresentation
    public let switchPeer: ChatContextResultSwitchPeer?
    public let results: [ChatContextResult]
    public let cacheTimeout: Int32
    
    init(botId: PeerId, queryId: Int64, nextOffset: String?, presentation: ChatContextResultCollectionPresentation, switchPeer: ChatContextResultSwitchPeer?, results: [ChatContextResult], cacheTimeout: Int32) {
        self.botId = botId
        self.queryId = queryId
        self.nextOffset = nextOffset
        self.presentation = presentation
        self.switchPeer = switchPeer
        self.results = results
        self.cacheTimeout = cacheTimeout
    }
    
    public static func ==(lhs: ChatContextResultCollection, rhs: ChatContextResultCollection) -> Bool {
        if lhs.botId != rhs.botId {
            return false
        }
        if lhs.queryId != rhs.queryId {
            return false
        }
        if lhs.nextOffset != rhs.nextOffset {
            return false
        }
        if lhs.presentation != rhs.presentation {
            return false
        }
        if lhs.switchPeer != rhs.switchPeer {
            return false
        }
        if lhs.results != rhs.results {
            return false
        }
        if lhs.cacheTimeout != rhs.cacheTimeout {
            return false
        }
        return true
    }
}

extension ChatContextResultMessage {
    init(apiMessage: Api.BotInlineMessage) {
        switch apiMessage {
            case let .botInlineMessageMediaAuto(_, caption, replyMarkup):
                var parsedReplyMarkup: ReplyMarkupMessageAttribute?
                if let replyMarkup = replyMarkup {
                    parsedReplyMarkup = ReplyMarkupMessageAttribute(apiMarkup: replyMarkup)
                }
                self = .auto(caption: caption, replyMarkup: parsedReplyMarkup)
            case let .botInlineMessageText(flags, message, entities, replyMarkup):
                var parsedEntities: TextEntitiesMessageAttribute?
                if let entities = entities, !entities.isEmpty {
                    parsedEntities = TextEntitiesMessageAttribute(entities: messageTextEntitiesFromApiEntities(entities))
                }
                var parsedReplyMarkup: ReplyMarkupMessageAttribute?
                if let replyMarkup = replyMarkup {
                    parsedReplyMarkup = ReplyMarkupMessageAttribute(apiMarkup: replyMarkup)
                }
                self = .text(text: message, entities: parsedEntities, disableUrlPreview: (flags & (1 << 0)) != 0, replyMarkup: parsedReplyMarkup)
            case let .botInlineMessageMediaGeo(_, geo, replyMarkup):
                let media = telegramMediaMapFromApiGeoPoint(geo, title: nil, address: nil, provider: nil, venueId: nil, venueType: nil, liveBroadcastingTimeout: nil)
                var parsedReplyMarkup: ReplyMarkupMessageAttribute?
                if let replyMarkup = replyMarkup {
                    parsedReplyMarkup = ReplyMarkupMessageAttribute(apiMarkup: replyMarkup)
                }
                self = .mapLocation(media: media, replyMarkup: parsedReplyMarkup)
            case let .botInlineMessageMediaVenue(_, geo, title, address, provider, venueId, replyMarkup):
                let media = telegramMediaMapFromApiGeoPoint(geo, title: title, address: address, provider: provider, venueId: venueId, venueType: nil, liveBroadcastingTimeout: nil)
                var parsedReplyMarkup: ReplyMarkupMessageAttribute?
                if let replyMarkup = replyMarkup {
                    parsedReplyMarkup = ReplyMarkupMessageAttribute(apiMarkup: replyMarkup)
                }
                self = .mapLocation(media: media, replyMarkup: parsedReplyMarkup)
            case let .botInlineMessageMediaContact(_, phoneNumber, firstName, lastName, replyMarkup):
                let media = TelegramMediaContact(firstName: firstName, lastName: lastName, phoneNumber: phoneNumber, peerId: nil)
                var parsedReplyMarkup: ReplyMarkupMessageAttribute?
                if let replyMarkup = replyMarkup {
                    parsedReplyMarkup = ReplyMarkupMessageAttribute(apiMarkup: replyMarkup)
                }
                self = .contact(media: media, replyMarkup: parsedReplyMarkup)
        }
    }
}

extension ChatContextResult {
    init(apiResult: Api.BotInlineResult) {
        switch apiResult {
            case let .botInlineResult(_, id, type, title, description, url, thumbUrl, contentUrl, contentType, w, h, duration, sendMessage):
                var dimensions: CGSize?
                if let w = w, let h = h {
                    dimensions = CGSize(width: CGFloat(w), height: CGFloat(h))
                }
                self = .externalReference(id: id, type: type, title: title, description: description, url: url, thumbnailUrl: thumbUrl, contentUrl: contentUrl, contentType: contentType, dimensions: dimensions, duration: duration, message: ChatContextResultMessage(apiMessage: sendMessage))
            case let .botInlineMediaResult(_, id, type, photo, document, title, description, sendMessage):
                var image: TelegramMediaImage?
                var file: TelegramMediaFile?
                if let photo = photo, let parsedImage = telegramMediaImageFromApiPhoto(photo) {
                    image = parsedImage
                }
                if let document = document, let parsedFile = telegramMediaFileFromApiDocument(document) {
                    file = parsedFile
                }
                self = .internalReference(id: id, type: type, title: title, description: description, image: image, file: file, message: ChatContextResultMessage(apiMessage: sendMessage))
        }
    }
}

extension ChatContextResultSwitchPeer {
    init(apiSwitchPeer: Api.InlineBotSwitchPM) {
        switch apiSwitchPeer {
            case let .inlineBotSwitchPM(text, startParam):
                self.init(text: text, startParam: startParam)
        }
    }
}

extension ChatContextResultCollection {
    convenience init(apiResults: Api.messages.BotResults, botId: PeerId) {
        switch apiResults {
            case let .botResults(flags, queryId, nextOffset, switchPm, results, cacheTime, users):
                var switchPeer: ChatContextResultSwitchPeer?
                if let switchPm = switchPm {
                    switchPeer = ChatContextResultSwitchPeer(apiSwitchPeer: switchPm)
                }
                self.init(botId: botId, queryId: queryId, nextOffset: nextOffset, presentation: (flags & (1 << 0) != 0) ? .media : .list, switchPeer: switchPeer, results: results.map { ChatContextResult(apiResult: $0) }, cacheTimeout: cacheTime)
        }
    }
}
