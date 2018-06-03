import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

public func markMessageContentAsConsumedInteractively(postbox: Postbox, messageId: MessageId) -> Signal<Void, NoError> {
    return postbox.modify { modifier -> Void in
        if let message = modifier.getMessage(messageId), message.flags.contains(.Incoming) {
            var updateMessage = false
            var updatedAttributes = message.attributes
            
            for i in 0 ..< updatedAttributes.count {
                if let attribute = updatedAttributes[i] as? ConsumableContentMessageAttribute {
                    if !attribute.consumed {
                        updatedAttributes[i] = ConsumableContentMessageAttribute(consumed: true)
                        updateMessage = true
                        
                        addSynchronizeConsumeMessageContentsOperation(modifier: modifier, messageIds: [message.id])
                    }
                } else if let attribute = updatedAttributes[i] as? ConsumablePersonalMentionMessageAttribute, !attribute.consumed {
                    modifier.setPendingMessageAction(type: .consumeUnseenPersonalMessage, id: messageId, action: ConsumePersonalMessageAction())
                    updatedAttributes[i] = ConsumablePersonalMentionMessageAttribute(consumed: attribute.consumed, pending: true)
                }
            }
            
            let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
            for i in 0 ..< updatedAttributes.count {
                if let attribute = updatedAttributes[i] as? AutoremoveTimeoutMessageAttribute {
                    if (attribute.countdownBeginTime == nil || attribute.countdownBeginTime == 0) && message.containsSecretMedia {
                        updatedAttributes[i] = AutoremoveTimeoutMessageAttribute(timeout: attribute.timeout, countdownBeginTime: timestamp)
                        updateMessage = true
                        
                        modifier.addTimestampBasedMessageAttribute(tag: 0, timestamp: timestamp + attribute.timeout, messageId: messageId)
                        
                        if messageId.peerId.namespace == Namespaces.Peer.SecretChat {
                            var layer: SecretChatLayer?
                            let state = modifier.getPeerChatState(message.id.peerId) as? SecretChatState
                            if let state = state {
                                switch state.embeddedState {
                                    case .terminated, .handshake:
                                        break
                                    case .basicLayer:
                                        layer = .layer8
                                    case let .sequenceBasedLayer(sequenceState):
                                        layer = SecretChatLayer(rawValue: sequenceState.layerNegotiationState.activeLayer)
                                }
                            }
                            
                            if let state = state, let layer = layer, let globallyUniqueId = message.globallyUniqueId {
                                let updatedState = addSecretChatOutgoingOperation(modifier: modifier, peerId: messageId.peerId, operation: .readMessagesContent(layer: layer, actionGloballyUniqueId: arc4random64(), globallyUniqueIds: [globallyUniqueId]), state: state)
                                if updatedState != state {
                                    modifier.setPeerChatState(messageId.peerId, state: updatedState)
                                }
                            }
                        }
                    }
                    break
                }
            }
            
            if updateMessage {
                modifier.updateMessage(message.id, update: { currentMessage in
                    var storeForwardInfo: StoreMessageForwardInfo?
                    if let forwardInfo = currentMessage.forwardInfo {
                        storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature)
                    }
                    return .update(StoreMessage(id: currentMessage.id, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: updatedAttributes, media: currentMessage.media))
                })
            }
        }
    }
}

func markMessageContentAsConsumedRemotely(modifier: Modifier, messageId: MessageId) {
    if let message = modifier.getMessage(messageId) {
        var updateMessage = false
        var updatedAttributes = message.attributes
        var updatedMedia = message.media
        var updatedTags = message.tags
        
        for i in 0 ..< updatedAttributes.count {
            if let attribute = updatedAttributes[i] as? ConsumableContentMessageAttribute {
                if !attribute.consumed {
                    updatedAttributes[i] = ConsumableContentMessageAttribute(consumed: true)
                    updateMessage = true
                }
            } else if let attribute = updatedAttributes[i] as? ConsumablePersonalMentionMessageAttribute, !attribute.consumed {
                if attribute.pending {
                    modifier.setPendingMessageAction(type: .consumeUnseenPersonalMessage, id: messageId, action: nil)
                }
                updatedAttributes[i] = ConsumablePersonalMentionMessageAttribute(consumed: true, pending: false)
                updatedTags.remove(.unseenPersonalMessage)
                updateMessage = true
            }
        }
        
        let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
        for i in 0 ..< updatedAttributes.count {
            if let attribute = updatedAttributes[i] as? AutoremoveTimeoutMessageAttribute {
                if (attribute.countdownBeginTime == nil || attribute.countdownBeginTime == 0) && message.containsSecretMedia {
                    updatedAttributes[i] = AutoremoveTimeoutMessageAttribute(timeout: attribute.timeout, countdownBeginTime: timestamp)
                    updateMessage = true
                    
                    if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
                        modifier.addTimestampBasedMessageAttribute(tag: 0, timestamp: timestamp + attribute.timeout, messageId: messageId)
                    } else {
                        for i in 0 ..< updatedMedia.count {
                            if let _ = updatedMedia[i] as? TelegramMediaImage {
                                updatedMedia[i] = TelegramMediaExpiredContent(data: .image)
                            } else if let _ = updatedMedia[i] as? TelegramMediaFile {
                                updatedMedia[i] = TelegramMediaExpiredContent(data: .file)
                            }
                        }
                    }
                }
                break
            }
        }
        
        if updateMessage {
            modifier.updateMessage(message.id, update: { currentMessage in
                var storeForwardInfo: StoreMessageForwardInfo?
                if let forwardInfo = currentMessage.forwardInfo {
                    storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature)
                }
                return .update(StoreMessage(id: currentMessage.id, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: updatedTags, globalTags: currentMessage.globalTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: updatedAttributes, media: updatedMedia))
            })
        }
    }
}

