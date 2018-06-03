import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

private func applyMediaResourceChanges(from: Media, to: Media, postbox: Postbox) {
    if let fromImage = from as? TelegramMediaImage, let toImage = to as? TelegramMediaImage {
        let fromSmallestRepresentation = smallestImageRepresentation(fromImage.representations)
        if let fromSmallestRepresentation = fromSmallestRepresentation, let toSmallestRepresentation = smallestImageRepresentation(toImage.representations) {
            postbox.mediaBox.moveResourceData(from: fromSmallestRepresentation.resource.id, to: toSmallestRepresentation.resource.id)
        }
        if let fromLargestRepresentation = largestImageRepresentation(fromImage.representations), let toLargestRepresentation = largestImageRepresentation(toImage.representations) {
            postbox.mediaBox.moveResourceData(from: fromLargestRepresentation.resource.id, to: toLargestRepresentation.resource.id)
        }
    } else if let fromFile = from as? TelegramMediaFile, let toFile = to as? TelegramMediaFile {
        if let fromPreview = smallestImageRepresentation(fromFile.previewRepresentations), let toPreview = smallestImageRepresentation(toFile.previewRepresentations) {
            postbox.mediaBox.moveResourceData(from: fromPreview.resource.id, to: toPreview.resource.id)
        }
        if fromFile.size == toFile.size && fromFile.mimeType == toFile.mimeType {
            postbox.mediaBox.moveResourceData(from: fromFile.resource.id, to: toFile.resource.id)
        } 
    }
}

func applyUpdateMessage(postbox: Postbox, stateManager: AccountStateManager, message: Message, result: Api.Updates) -> Signal<Void, NoError> {
    return postbox.modify { modifier -> Void in
        let messageId = result.rawMessageIds.first
        let apiMessage = result.messages.first
        
        var updatedTimestamp: Int32?
        if let apiMessage = apiMessage {
            switch apiMessage {
                case let .message(_, _, _, _, _, _, _, date, _, _, _, _, _, _, _, _):
                    updatedTimestamp = date
                case .messageEmpty:
                    break
                case let .messageService(_, _, _, _, _, date, _):
                    updatedTimestamp = date
            }
        } else {
            switch result {
                case let .updateShortSentMessage(_, _, _, _, date, _, _):
                    updatedTimestamp = date
                default:
                    break
            }
        }
        
        var sentStickers: [TelegramMediaFile] = []
        var sentGifs: [TelegramMediaFile] = []
        
        modifier.updateMessage(message.id, update: { currentMessage in
            let updatedId: MessageId
            if let messageId = messageId {
                updatedId = MessageId(peerId: currentMessage.id.peerId, namespace: Namespaces.Message.Cloud, id: messageId)
            } else {
                updatedId = currentMessage.id
            }
            
            let media: [Media]
            let attributes: [MessageAttribute]
            let text: String
            if let apiMessage = apiMessage, let updatedMessage = StoreMessage(apiMessage: apiMessage) {
                media = updatedMessage.media
                attributes = updatedMessage.attributes
                text = updatedMessage.text
            } else if case let .updateShortSentMessage(_, _, _, _, _, apiMedia, entities) = result {
                let (_, mediaValue, _) = textMediaAndExpirationTimerFromApiMedia(apiMedia, currentMessage.id.peerId)
                if let mediaValue = mediaValue {
                    media = [mediaValue]
                } else {
                    media = []
                }
                
                var updatedAttributes: [MessageAttribute] = currentMessage.attributes
                if let entities = entities, !entities.isEmpty {
                    for i in 0 ..< updatedAttributes.count {
                        if updatedAttributes[i] is TextEntitiesMessageAttribute {
                            updatedAttributes.remove(at: i)
                            break
                        }
                    }
                    updatedAttributes.append(TextEntitiesMessageAttribute(entities: messageTextEntitiesFromApiEntities(entities)))
                }
                
                attributes = updatedAttributes
                text = currentMessage.text
            } else {
                media = currentMessage.media
                attributes = currentMessage.attributes
                text = currentMessage.text
            }
            
            var storeForwardInfo: StoreMessageForwardInfo?
            if let forwardInfo = currentMessage.forwardInfo {
                storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature)
            }
            
            if let fromMedia = currentMessage.media.first, let toMedia = media.first {
                applyMediaResourceChanges(from: fromMedia, to: toMedia, postbox: postbox)
            }
            
            if storeForwardInfo == nil {
                for media in media {
                    if let file = media as? TelegramMediaFile {
                        if file.isSticker {
                            sentStickers.append(file)
                        } else if file.isVideo && file.isAnimated {
                            sentGifs.append(file)
                        }
                    }
                }
            }
            
            var entitiesAttribute: TextEntitiesMessageAttribute?
            for attribute in attributes {
                if let attribute = attribute as? TextEntitiesMessageAttribute {
                    entitiesAttribute = attribute
                    break
                }
            }
            
            let (tags, globalTags) = tagsForStoreMessage(incoming: currentMessage.flags.contains(.Incoming), attributes: attributes, media: media, textEntities: entitiesAttribute?.entities)
            
            return .update(StoreMessage(id: updatedId, globallyUniqueId: nil, groupingKey: currentMessage.groupingKey, timestamp: updatedTimestamp ?? currentMessage.timestamp, flags: [], tags: tags, globalTags: globalTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: text, attributes: attributes, media: media))
        })
        if let updatedTimestamp = updatedTimestamp {
            modifier.offsetPendingMessagesTimestamps(lowerBound: message.id, timestamp: updatedTimestamp)
        }
        for file in sentStickers {
            modifier.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.CloudRecentStickers, item: OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: RecentMediaItem(file)), removeTailIfCountExceeds: 20)
        }
        for file in sentGifs {
            modifier.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.CloudRecentGifs, item: OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: RecentMediaItem(file)), removeTailIfCountExceeds: 200)
        }
        stateManager.addUpdates(result)
    }
}

func applyUpdateGroupMessages(postbox: Postbox, stateManager: AccountStateManager, messages: [Message], result: Api.Updates) -> Signal<Void, NoError> {
    guard !messages.isEmpty else {
        return .complete()
    }
    
    return postbox.modify { modifier -> Void in
        let updatedRawMessageIds = result.updatedRawMessageIds
        
        var resultMessages: [MessageId: StoreMessage] = [:]
        for apiMessage in result.messages {
            if let resultMessage = StoreMessage(apiMessage: apiMessage), case let .Id(id) = resultMessage.id {
                resultMessages[id] = resultMessage
            }
        }
        
        var mapping: [(Message, MessageIndex, StoreMessage)] = []
        
        for message in messages {
            var uniqueId: Int64?
            inner: for attribute in message.attributes {
                if let outgoingInfo = attribute as? OutgoingMessageInfoAttribute {
                    uniqueId = outgoingInfo.uniqueId
                    break inner
                }
            }
            if let uniqueId = uniqueId {
                if let updatedId = updatedRawMessageIds[uniqueId] {
                    if let storeMessage = resultMessages[MessageId(peerId: message.id.peerId, namespace: Namespaces.Message.Cloud, id: updatedId)], case let .Id(id) = storeMessage.id {
                        mapping.append((message, MessageIndex(id: id, timestamp: storeMessage.timestamp), storeMessage))
                    }
                } else {
                    assertionFailure()
                }
            } else {
                assertionFailure()
            }
        }
        
        mapping.sort { $0.1 < $1.1 }
        
        var sentStickers: [TelegramMediaFile] = []
        var sentGifs: [TelegramMediaFile] = []
        
        var updatedGroupingKey: Int64?
        
        for (message, _, updatedMessage) in mapping {
            modifier.updateMessage(message.id, update: { currentMessage in
                let updatedId: MessageId
                if case let .Id(id) = updatedMessage.id {
                    updatedId = id
                } else {
                    updatedId = currentMessage.id
                }
                
                let media: [Media]
                let attributes: [MessageAttribute]
                let text: String
 
                media = updatedMessage.media
                attributes = updatedMessage.attributes
                text = updatedMessage.text
                
                var storeForwardInfo: StoreMessageForwardInfo?
                if let forwardInfo = currentMessage.forwardInfo {
                    storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature)
                }
                
                if let fromMedia = currentMessage.media.first, let toMedia = media.first {
                    applyMediaResourceChanges(from: fromMedia, to: toMedia, postbox: postbox)
                }
                
                if storeForwardInfo == nil {
                    for media in media {
                        if let file = media as? TelegramMediaFile {
                            if file.isSticker {
                                sentStickers.append(file)
                            } else if file.isVideo && file.isAnimated {
                                sentGifs.append(file)
                            }
                        }
                    }
                }
                
                var entitiesAttribute: TextEntitiesMessageAttribute?
                for attribute in attributes {
                    if let attribute = attribute as? TextEntitiesMessageAttribute {
                        entitiesAttribute = attribute
                        break
                    }
                }
                
                let (tags, globalTags) = tagsForStoreMessage(incoming: currentMessage.flags.contains(.Incoming), attributes: attributes, media: media, textEntities: entitiesAttribute?.entities)
                
                if let updatedGroupingKey = updatedGroupingKey {
                    assert(updatedGroupingKey == updatedMessage.groupingKey)
                }
                updatedGroupingKey = updatedMessage.groupingKey
                
                return .update(StoreMessage(id: updatedId, globallyUniqueId: nil, groupingKey: currentMessage.groupingKey, timestamp: updatedMessage.timestamp, flags: [], tags: tags, globalTags: globalTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: text, attributes: attributes, media: media))
            })
        }
        
        if let updatedGroupingKey = updatedGroupingKey {
            modifier.updateMessageGroupingKeysAtomically(mapping.map { $0.1.id }, groupingKey: updatedGroupingKey)
        }
        
        if let latestIndex = mapping.last?.1 {
            modifier.offsetPendingMessagesTimestamps(lowerBound: latestIndex.id, timestamp: latestIndex.timestamp)
        }
        
        for file in sentStickers {
            modifier.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.CloudRecentStickers, item: OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: RecentMediaItem(file)), removeTailIfCountExceeds: 20)
        }
        for file in sentGifs {
            modifier.addOrMoveToFirstPositionOrderedItemListItem(collectionId: Namespaces.OrderedItemList.CloudRecentGifs, item: OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: RecentMediaItem(file)), removeTailIfCountExceeds: 200)
        }
        stateManager.addUpdates(result)
    }
}
