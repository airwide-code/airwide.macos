import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

public enum EnqueueMessageGrouping {
    case none
    case auto
}

public enum EnqueueMessage {
    case message(text: String, attributes: [MessageAttribute], media: Media?, replyToMessageId: MessageId?, localGroupingKey: Int64?)
    case forward(source: MessageId, grouping: EnqueueMessageGrouping)
    
    public func withUpdatedReplyToMessageId(_ replyToMessageId: MessageId?) -> EnqueueMessage {
        switch self {
            case let .message(text, attributes, media, _, localGroupingKey):
                return .message(text: text, attributes: attributes, media: media, replyToMessageId: replyToMessageId, localGroupingKey: localGroupingKey)
            case .forward:
                return self
        }
    }
}

private func filterMessageAttributesForOutgoingMessage(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    return attributes.filter { attribute in
        switch attribute {
            case _ as TextEntitiesMessageAttribute:
                return true
            case _ as InlineBotMessageAttribute:
                return true
            case _ as OutgoingMessageInfoAttribute:
                return true
            case _ as OutgoingContentInfoMessageAttribute:
                return true
            case _ as ReplyMarkupMessageAttribute:
                return true
            case _ as OutgoingChatContextResultMessageAttribute:
                return true
            case _ as AutoremoveTimeoutMessageAttribute:
                return true
            case _ as NotificationInfoMessageAttribute:
                return true
            default:
                return false
        }
    }
}

private func filterMessageAttributesForForwardedMessage(_ attributes: [MessageAttribute]) -> [MessageAttribute] {
    return attributes.filter { attribute in
        switch attribute {
            case _ as TextEntitiesMessageAttribute:
                return true
            case _ as InlineBotMessageAttribute:
                return true
            default:
                return false
        }
    }
}

func opportunisticallyTransformMessageWithMedia(network: Network, postbox: Postbox, transformOutgoingMessageMedia: TransformOutgoingMessageMedia, media: Media, userInteractive: Bool) -> Signal<Media?, NoError> {
    return transformOutgoingMessageMedia(postbox, network, media, userInteractive)
        |> timeout(2.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(nil))
}

private func opportunisticallyTransformOutgoingMedia(network: Network, postbox: Postbox, transformOutgoingMessageMedia: TransformOutgoingMessageMedia, messages: [EnqueueMessage], userInteractive: Bool) -> Signal<[(Bool, EnqueueMessage)], NoError> {
    var hasMedia = false
    loop: for message in messages {
        switch message {
            case let .message(_, _, media, _, _):
                if media != nil {
                    hasMedia = true
                    break loop
                }
            case .forward:
                break
        }
    }
    
    if !hasMedia {
        return .single(messages.map { (true, $0) })
    }
    
    var signals: [Signal<(Bool, EnqueueMessage), NoError>] = []
    for message in messages {
        switch message {
            case let .message(text, attributes, media, replyToMessageId, localGroupingKey):
                if let media = media {
                    signals.append(opportunisticallyTransformMessageWithMedia(network: network, postbox: postbox, transformOutgoingMessageMedia: transformOutgoingMessageMedia, media: media, userInteractive: userInteractive) |> map { result -> (Bool, EnqueueMessage) in
                        if let result = result {
                            return (true, .message(text: text, attributes: attributes, media: result, replyToMessageId: replyToMessageId, localGroupingKey: localGroupingKey))
                        } else {
                            return (false, .message(text: text, attributes: attributes, media: media, replyToMessageId: replyToMessageId, localGroupingKey: localGroupingKey))
                        }
                    })
                } else {
                    signals.append(.single((false, message)))
                }
            case .forward:
                signals.append(.single((false, message)))
        }
    }
    return combineLatest(signals)
}

public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {
    let signal: Signal<[(Bool, EnqueueMessage)], NoError>
    if let transformOutgoingMessageMedia = account.transformOutgoingMessageMedia {
        signal = opportunisticallyTransformOutgoingMedia(network: account.network, postbox: account.postbox, transformOutgoingMessageMedia: transformOutgoingMessageMedia, messages: messages, userInteractive: true)
    } else {
        signal = .single(messages.map { (false, $0) })
    }
    return signal
        |> mapToSignal { messages -> Signal<[MessageId?], NoError> in
        return account.postbox.modify { modifier -> [MessageId?] in
            return enqueueMessages(modifier: modifier, account: account, peerId: peerId, messages: messages)
        }
    }
}

public func enqueueMessagesToMultiplePeers(account: Account, peerIds: [PeerId], messages: [EnqueueMessage]) -> Signal<[MessageId], NoError> {
    let signal: Signal<[(Bool, EnqueueMessage)], NoError>
    if let transformOutgoingMessageMedia = account.transformOutgoingMessageMedia {
        signal = opportunisticallyTransformOutgoingMedia(network: account.network, postbox: account.postbox, transformOutgoingMessageMedia: transformOutgoingMessageMedia, messages: messages, userInteractive: true)
    } else {
        signal = .single(messages.map { (false, $0) })
    }
    return signal
        |> mapToSignal { messages -> Signal<[MessageId], NoError> in
            return account.postbox.modify { modifier -> [MessageId] in
                var messageIds: [MessageId] = []
                for peerId in peerIds {
                    for id in enqueueMessages(modifier: modifier, account: account, peerId: peerId, messages: messages) {
                        if let id = id {
                            messageIds.append(id)
                        }
                    }
                }
                return messageIds
            }
    }
}

public func resendMessages(account: Account, messageIds: [MessageId]) -> Signal<Void, NoError> {
    return account.postbox.modify { modifier -> Void in
        var removeMessageIds: [MessageId] = []
        for (peerId, ids) in messagesIdsGroupedByPeerId(messageIds) {
            var messages: [EnqueueMessage] = []
            for id in ids {
                if let message = modifier.getMessage(id), !message.flags.contains(.Incoming) {
                    removeMessageIds.append(id)
                    
                    var replyToMessageId: MessageId?
                    for attribute in message.attributes {
                        if let attribute = attribute as? ReplyMessageAttribute {
                            replyToMessageId = attribute.messageId
                        }
                    }
                    
                    messages.append(.message(text: message.text, attributes: message.attributes, media: message.media.first, replyToMessageId: replyToMessageId, localGroupingKey: message.groupingKey))
                }
            }
            let _ = enqueueMessages(modifier: modifier, account: account, peerId: peerId, messages: messages.map { (false, $0) })
        }
        modifier.deleteMessages(removeMessageIds)
    }
}

func enqueueMessages(modifier: Modifier, account: Account, peerId: PeerId, messages: [(Bool, EnqueueMessage)]) -> [MessageId?] {
    if let peer = modifier.getPeer(peerId) {
        var storeMessages: [StoreMessage] = []
        var timestamp = Int32(account.network.context.globalTime())
        switch peerId.namespace {
            case Namespaces.Peer.CloudChannel, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudUser:
                if let topIndex = modifier.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud) {
                    timestamp = max(timestamp, topIndex.timestamp)
                }
            default:
                break
        }
        
        var addedHashtags: [String] = []
        
        var localGroupingKeyBySourceKey: [Int64: Int64] = [:]
        
        var globallyUniqueIds: [Int64] = []
        for (transformedMedia, message) in messages {
            var attributes: [MessageAttribute] = []
            var flags = StoreMessageFlags()
            flags.insert(.Unsent)
            
            var randomId: Int64 = 0
            arc4random_buf(&randomId, 8)
            var infoFlags = OutgoingMessageInfoFlags()
            if transformedMedia {
                infoFlags.insert(.transformedMedia)
            }
            attributes.append(OutgoingMessageInfoAttribute(uniqueId: randomId, flags: infoFlags))
            globallyUniqueIds.append(randomId)
            
            switch message {
                case let .message(text, requestedAttributes, media, replyToMessageId, localGroupingKey):
                    if let peer = peer as? TelegramSecretChat {
                        var isAction = false
                        if let _ = media as? TelegramMediaAction {
                            isAction = true
                        }
                        if let messageAutoremoveTimeout = peer.messageAutoremoveTimeout, !isAction {
                            attributes.append(AutoremoveTimeoutMessageAttribute(timeout: messageAutoremoveTimeout, countdownBeginTime: nil))
                        }
                    }
                    
                    attributes.append(contentsOf: filterMessageAttributesForOutgoingMessage(requestedAttributes))
                        
                    if let replyToMessageId = replyToMessageId {
                        attributes.append(ReplyMessageAttribute(messageId: replyToMessageId))
                    }
                    var mediaList: [Media] = []
                    if let media = media {
                        mediaList.append(media)
                    }
                    
                    if let file = media as? TelegramMediaFile, file.isVoice {
                        if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup {
                            attributes.append(ConsumableContentMessageAttribute(consumed: false))
                        }
                    }
                    
                    var entitiesAttribute: TextEntitiesMessageAttribute?
                    for attribute in attributes {
                        if let attribute = attribute as? TextEntitiesMessageAttribute {
                            entitiesAttribute = attribute
                            var maybeNsText: NSString?
                            for entity in attribute.entities {
                                if case .Hashtag = entity.type {
                                    let nsText: NSString
                                    if let maybeNsText = maybeNsText {
                                        nsText = maybeNsText
                                    } else {
                                        nsText = text as NSString
                                        maybeNsText = nsText
                                    }
                                    var entityRange = NSRange(location: entity.range.lowerBound, length: entity.range.upperBound - entity.range.lowerBound)
                                    if entityRange.location + entityRange.length > nsText.length {
                                        entityRange.location = max(0, nsText.length - entityRange.length)
                                        entityRange.length = nsText.length - entityRange.location
                                    }
                                    if entityRange.length > 1 {
                                        entityRange.location += 1
                                        entityRange.length -= 1
                                        let hashtag = nsText.substring(with: entityRange)
                                        addedHashtags.append(hashtag)
                                    }
                                }
                            }
                            break
                        }
                    }
                
                    let authorId: PeerId?
                    if let peer = peer as? TelegramChannel, case let .broadcast(info) = peer.info, !info.flags.contains(.messagesShouldHaveSignatures) {
                        authorId = peer.id
                    }  else {
                        authorId = account.peerId
                    }
                    
                    let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: attributes, media: mediaList, textEntities: entitiesAttribute?.entities)
                    
                    storeMessages.append(StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, globallyUniqueId: randomId, groupingKey: localGroupingKey, timestamp: timestamp, flags: flags, tags: tags, globalTags: globalTags, forwardInfo: nil, authorId: authorId, text: text, attributes: attributes, media: mediaList))
                case let .forward(source, grouping):
                    let sourceMessage = modifier.getMessage(source)
                    if let sourceMessage = sourceMessage, let author = sourceMessage.author ?? sourceMessage.peers[sourceMessage.id.peerId] {
                        if let peer = peer as? TelegramSecretChat {
                            var isAction = false
                            for media in sourceMessage.media {
                                if let _ = media as? TelegramMediaAction {
                                    isAction = true
                                    break
                                }
                            }
                            if let messageAutoremoveTimeout = peer.messageAutoremoveTimeout, !isAction {
                                attributes.append(AutoremoveTimeoutMessageAttribute(timeout: messageAutoremoveTimeout, countdownBeginTime: nil))
                            }
                        }
                        
                        attributes.append(ForwardSourceInfoAttribute(messageId: sourceMessage.id))
                        if peerId == account.peerId {
                            attributes.append(SourceReferenceMessageAttribute(messageId: sourceMessage.id))
                        }
                        attributes.append(contentsOf: filterMessageAttributesForForwardedMessage(sourceMessage.attributes))
                        let forwardInfo: StoreMessageForwardInfo?
                        if let sourceForwardInfo = sourceMessage.forwardInfo {
                            forwardInfo = StoreMessageForwardInfo(authorId: sourceForwardInfo.author.id, sourceId: sourceForwardInfo.source?.id, sourceMessageId: sourceForwardInfo.sourceMessageId, date: sourceForwardInfo.date, authorSignature: sourceForwardInfo.authorSignature)
                        } else {
                            if sourceMessage.id.peerId != account.peerId {
                                var sourceId:PeerId? = nil
                                var sourceMessageId:MessageId? = nil
                                if let peer = messageMainPeer(sourceMessage) as? TelegramChannel, case .broadcast = peer.info {
                                    sourceId = peer.id
                                    sourceMessageId = sourceMessage.id
                                }
                                forwardInfo = StoreMessageForwardInfo(authorId: author.id, sourceId: sourceId, sourceMessageId: sourceMessageId, date: sourceMessage.timestamp, authorSignature: nil)
                            } else {
                                forwardInfo = nil
                            }

                        }
                        
                        let authorId:PeerId?
                        if let peer = peer as? TelegramChannel, case let .broadcast(info) = peer.info, !info.flags.contains(.messagesShouldHaveSignatures) {
                            authorId = peer.id
                        }  else {
                            authorId = account.peerId
                        }
                        
                        var entitiesAttribute: TextEntitiesMessageAttribute?
                        for attribute in attributes {
                            if let attribute = attribute as? TextEntitiesMessageAttribute {
                                entitiesAttribute = attribute
                                break
                            }
                        }
                        
                        let (tags, globalTags) = tagsForStoreMessage(incoming: false, attributes: attributes, media: sourceMessage.media, textEntities: entitiesAttribute?.entities)
                        
                        let localGroupingKey: Int64?
                        switch grouping {
                            case .none:
                                localGroupingKey = nil
                            case .auto:
                                if let groupingKey = sourceMessage.groupingKey {
                                    if let generatedKey = localGroupingKeyBySourceKey[groupingKey] {
                                        localGroupingKey = generatedKey
                                    } else {
                                        let generatedKey = arc4random64()
                                        localGroupingKeyBySourceKey[groupingKey] = generatedKey
                                        localGroupingKey = generatedKey
                                    }
                                } else {
                                    localGroupingKey = nil
                                }
                        }
                        
                        storeMessages.append(StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, globallyUniqueId: randomId, groupingKey: localGroupingKey, timestamp: timestamp, flags: flags, tags: tags, globalTags: globalTags, forwardInfo: forwardInfo, authorId: authorId, text: sourceMessage.text, attributes: attributes, media: sourceMessage.media))
                    }
            }
        }
        var messageIds: [MessageId?] = []
        if !storeMessages.isEmpty {
            let globallyUniqueIdToMessageId = modifier.addMessages(storeMessages, location: .Random)
            for globallyUniqueId in globallyUniqueIds {
                messageIds.append(globallyUniqueIdToMessageId[globallyUniqueId])
            }
        }
        for hashtag in addedHashtags {
            addRecentlyUsedHashtag(modifier: modifier, string: hashtag)
        }
        return messageIds
    } else {
        return []
    }
}
