import Foundation
#if os(macOS)
    import PostboxMac
#else
    import Postbox
#endif

extension Api.MessageMedia {
    var preCachedResources: [(MediaResource, Data)]? {
        switch self {
            case let .messageMediaPhoto(_, photo, _, _):
                if let photo = photo {
                    switch photo {
                        case let .photo(_, _, _, _, sizes):
                            for size in sizes {
                                switch size {
                                    case let .photoCachedSize(_, location, _, _, bytes):
                                        switch location {
                                            case let .fileLocation(dcId, volumeId, localId, secret):
                                                let data = bytes.makeData()
                                                let resource = CloudFileMediaResource(datacenterId: Int(dcId), volumeId: volumeId, localId: localId, secret: secret, size: data.count)
                                                return [(resource, data)]
                                            default:
                                                break
                                        }
                                    default:
                                        break
                                }
                            }
                            return nil
                        default:
                            return nil
                    }
                } else {
                    return nil
                }
            case let .messageMediaDocument(_, document, _, _):
                if let document = document {
                    switch document {
                        case .document:
                            break
                        default:
                            break
                    }
                }
                return nil
            default:
                return nil
        }
    }
}

extension Api.Message {
    var rawId: Int32 {
        switch self {
            case let .message(_, id, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
                return id
            case let .messageEmpty(id):
                return id
            case let .messageService(_, id, _, _, _, _, _):
                return id
        }
    }
    
    var id: MessageId? {
        switch self {
            case let .message(flags, id, fromId, toId, _, _, _, _, _, _, _, _, _, _, _, _):
                let peerId: PeerId
                switch toId {
                    case let .peerUser(userId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: (flags & Int32(2)) != 0 ? userId : (fromId ?? userId))
                    case let .peerChat(chatId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                    case let .peerChannel(channelId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                }
                return MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id)
            case .messageEmpty:
                return nil
            case let .messageService(flags, id, fromId, toId, _, _, _):
                let peerId: PeerId
                switch toId {
                    case let .peerUser(userId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: (flags & Int32(2)) != 0 ? userId : (fromId ?? userId))
                    case let .peerChat(chatId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                    case let .peerChannel(channelId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                }
                
                return MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id)
        }
    }

    var timestamp: Int32? {
        switch self {
            case let .message(_, _, _, _, _, _, _, date, _, _, _, _, _, _, _, _):
                return date
            case let .messageService(_, _, _, _, _, date, _):
                return date
            case .messageEmpty:
                return nil
        }
    }
    
    var preCachedResources: [(MediaResource, Data)]? {
        switch self {
            case let .message(_, _, _, _, _, _, _, _, _, media, _, _, _, _, _, _):
                return media?.preCachedResources
            default:
                return nil
        }
    }
}

extension Api.Chat {
    var peerId: PeerId {
        switch self {
            case let .chat(_, id, _, _, _, _, _, _):
                return PeerId(namespace: Namespaces.Peer.CloudGroup, id: id)
            case let .chatEmpty(id):
                return PeerId(namespace: Namespaces.Peer.CloudGroup, id: id)
            case let .chatForbidden(id, _):
                return PeerId(namespace: Namespaces.Peer.CloudGroup, id: id)
            case let .channel(_, id, _, _, _, _, _, _, _, _, _, _):
                return PeerId(namespace: Namespaces.Peer.CloudChannel, id: id)
            case let .channelForbidden(_, id, _, _, _):
                return PeerId(namespace: Namespaces.Peer.CloudChannel, id: id)
        }
    }
}

extension Api.User {
    var peerId: PeerId {
        switch self {
            case .user(_, let id, _, _, _, _, _, _, _, _, _, _, _):
                return PeerId(namespace: Namespaces.Peer.CloudUser, id: id)
            case let .userEmpty(id):
                return PeerId(namespace: Namespaces.Peer.CloudUser, id: id)
        }
    }
}

extension Api.Peer {
    var peerId: PeerId {
        switch self {
            case let .peerChannel(channelId):
                return PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
            case let .peerChat(chatId):
                return PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
            case let .peerUser(userId):
                return PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
        }
    }
}

extension Api.Dialog {
    var peerId: PeerId {
        switch self {
            case let .dialog(_, peer, _, _, _, _, _, _, _, _):
                return peer.peerId
        }
    }
}

extension Api.Update {
    var rawMessageId: Int32? {
        switch self {
            case let .updateMessageID(id, _):
                return id
            case let .updateNewMessage(message, _, _):
                return message.rawId
            case let .updateNewChannelMessage(message, _, _):
                return message.rawId
            default:
                return nil
        }
    }
    
    var updatedRawMessageId: (Int64, Int32)? {
        switch self {
            case let .updateMessageID(id, randomId):
                return (randomId, id)
            default:
                return nil
        }
    }
    
    var messageId: MessageId? {
        switch self {
            case let .updateNewMessage(message, _, _):
                return message.id
            case let .updateNewChannelMessage(message, _, _):
                return message.id
            default:
                return nil
        }
    }
    
    var message: Api.Message? {
        switch self {
            case let .updateNewMessage(message, _, _):
                return message
            case let .updateNewChannelMessage(message, _, _):
                return message
            case let .updateEditMessage(message, _, _):
                return message
            case let .updateEditChannelMessage(message, _, _):
                return message
            default:
                return nil
        }
    }
    
    var peerIds: [PeerId] {
        switch self {
            case let .updateChannel(channelId):
                return [PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)]
            case let .updateChannelTooLong(_, channelId, _):
                return [PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)]
            case let .updateChatAdmins(chatId, _, _):
                return [PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)]
            case let .updateChatParticipantAdd(chatId, userId, inviterId, _, _):
                return [PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId), PeerId(namespace: Namespaces.Peer.CloudUser, id: userId), PeerId(namespace: Namespaces.Peer.CloudUser, id: inviterId)]
            case let .updateChatParticipantAdmin(chatId, userId, _, _):
                return [PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId), PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)]
            case let .updateChatParticipantDelete(chatId, userId, _):
                return [PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId), PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)]
            case let .updateChatParticipants(participants):
                switch participants {
                    case let .chatParticipants(chatId, _, _):
                        return [PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)]
                    case let .chatParticipantsForbidden(_, chatId, _):
                        return [PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)]
                }
            case let .updateContactRegistered(userId, _):
                return [PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)]
            case let .updateDeleteChannelMessages(channelId, _, _, _):
                return [PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)]
            case let .updateNewChannelMessage(message, _, _):
                return message.peerIds
            case let .updateEditChannelMessage(message, _, _):
                return message.peerIds
            case let .updateChannelWebPage(channelId, _, _, _):
                return [PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)]
            case let .updateNewMessage(message, _, _):
                return message.peerIds
            case let .updateEditMessage(message, _, _):
                return message.peerIds
            //case let .updateReadChannelInbox(channelId, _):
            //    return [PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)]
            case let .updateUserName(userId, _, _, _):
                return [PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)]
            case let .updateUserPhone(userId, _):
                return [PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)]
            case let .updateUserPhoto(userId, _, _, _):
                return [PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)]
            case let .updateServiceNotification(_, inboxDate, _, _, _, _):
                if let _ = inboxDate {
                    return [PeerId(namespace: Namespaces.Peer.CloudUser, id: 777000)]
                } else {
                    return []
                }
            case let .updateDraftMessage(peer: peer, draft: _):
                return [peer.peerId]
            default:
                return []
        }
    }
    
    var associatedMessageIds: [MessageId]? {
        switch self {
            case let .updateNewMessage(message, _, _):
                return message.associatedMessageIds
            case let .updateNewChannelMessage(message, _, _):
                return message.associatedMessageIds
            case let .updateEditChannelMessage(message, _, _):
                return message.associatedMessageIds
            default:
                break
        }
        return nil
    }
}

extension Api.Updates {
    var rawMessageIds: [Int32] {
        switch self {
            case let .updates(updates, _, _, _, _):
                var result: [Int32] = []
                for update in updates {
                    if let id = update.rawMessageId {
                        result.append(id)
                    }
                }
                return result
            case let .updatesCombined(updates, _, _, _, _, _):
                var result: [Int32] = []
                for update in updates {
                    if let id = update.rawMessageId {
                        result.append(id)
                    }
                }
                return result
            case let .updateShort(update, _):
                if let id = update.rawMessageId {
                    return [id]
                } else {
                    return []
                }
            case let .updateShortSentMessage(_, id, _, _, _, _, _):
                return [id]
            case .updatesTooLong:
                return []
            case let .updateShortMessage(_, id, _, _, _, _, _, _, _, _, _):
                return [id]
            case let .updateShortChatMessage(_, id, _, _, _, _, _, _, _, _, _, _):
                return [id]
        }
    }
    
    var messageIds: [MessageId] {
        switch self {
            case let .updates(updates, _, _, _, _):
                var result: [MessageId] = []
                for update in updates {
                    if let id = update.messageId {
                        result.append(id)
                    }
                }
                return result
            case let .updatesCombined(updates, _, _, _, _, _):
                var result: [MessageId] = []
                for update in updates {
                    if let id = update.messageId {
                        result.append(id)
                    }
                }
                return result
            case let .updateShort(update, _):
                if let id = update.messageId {
                    return [id]
                } else {
                    return []
                }
            case .updateShortSentMessage:
                return []
            case .updatesTooLong:
                return []
            case let .updateShortMessage(_, id, userId, _, _, _, _, _, _, _, _):
                return [MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: userId), namespace: Namespaces.Message.Cloud, id: id)]
            case let .updateShortChatMessage(_, id, _, chatId, _, _, _, _, _, _, _, _):
                return [MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId), namespace: Namespaces.Message.Cloud, id: id)]
        }
    }
    
    var updatedRawMessageIds: [Int64: Int32] {
        switch self {
            case let .updates(updates, _, _, _, _):
                var result: [Int64: Int32] = [:]
                for update in updates {
                    if let (randomId, id) = update.updatedRawMessageId {
                        result[randomId] = id
                    }
                }
                return result
            case let .updatesCombined(updates, _, _, _, _, _):
                var result: [Int64: Int32] = [:]
                for update in updates {
                    if let (randomId, id) = update.updatedRawMessageId {
                        result[randomId] = id
                    }
                }
                return result
            case let .updateShort(update, _):
                if let (randomId, id) = update.updatedRawMessageId {
                    return [randomId: id]
                } else {
                    return [:]
                }
            case .updateShortSentMessage:
                return [:]
            case .updatesTooLong:
                return [:]
            case let .updateShortMessage(_, id, userId, _, _, _, _, _, _, _, _):
                return [:]
            case let .updateShortChatMessage(_, id, _, chatId, _, _, _, _, _, _, _, _):
                return [:]
        }
    }
}

extension Api.Updates {
    var messages: [Api.Message] {
        switch self {
            case let .updates(updates, _, _, _, _):
                var result: [Api.Message] = []
                for update in updates {
                    if let message = update.message {
                        result.append(message)
                    }
                }
                return result
            case let .updatesCombined(updates, _, _, _, _, _):
                var result: [Api.Message] = []
                for update in updates {
                    if let message = update.message {
                        result.append(message)
                    }
                }
                return result
            case let .updateShort(update, _):
                if let message = update.message {
                    return [message]
                } else {
                    return []
                }
            default:
                return []
        }
    }
}

extension Api.Updates {
    var chats: [Api.Chat] {
        switch self {
        case let .updates(_, _, chats, _, _):
            var result: [Api.Chat] = []
            for chat in chats {
                result.append(chat)
            }
            return result
        case let .updatesCombined(_, _, chats, _, _, _):
            var result: [Api.Chat] = []
            for chat in chats {
                result.append(chat)
            }
            return result
        default:
            return []
        }
    }
}

extension Api.EncryptedChat {
    var peerId: PeerId {
        switch self {
            case let .encryptedChat(id, _, _, _, _, _, _):
                return PeerId(namespace: Namespaces.Peer.SecretChat, id: id)
            case let .encryptedChatDiscarded(id):
                return PeerId(namespace: Namespaces.Peer.SecretChat, id: id)
            case let .encryptedChatEmpty(id):
                return PeerId(namespace: Namespaces.Peer.SecretChat, id: id)
            case let .encryptedChatRequested(id, _, _, _, _, _):
                return PeerId(namespace: Namespaces.Peer.SecretChat, id: id)
            case let .encryptedChatWaiting(id, _, _, _, _):
                return PeerId(namespace: Namespaces.Peer.SecretChat, id: id)
        }
    }
}

extension Api.EncryptedMessage {
    var peerId: PeerId {
        switch self {
            case let .encryptedMessage(_, chatId, _, _, _):
                return PeerId(namespace: Namespaces.Peer.SecretChat, id: chatId)
            case let .encryptedMessageService(_, chatId, _, _):
                return PeerId(namespace: Namespaces.Peer.SecretChat, id: chatId)
        }
    }
}
