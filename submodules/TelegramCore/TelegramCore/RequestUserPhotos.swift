
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


public struct TelegramPeerPhoto {
    public let image: TelegramMediaImage
    public let reference: TelegramMediaImageReference?
    public let index:Int
    public let totalCount:Int
}

public func requestPeerPhotos(account:Account, peerId:PeerId) -> Signal<[TelegramPeerPhoto], Void> {
    return account.postbox.modify{ modifier -> Peer? in
        return modifier.getPeer(peerId)
        } |> mapToSignal { peer -> Signal<[TelegramPeerPhoto], Void> in
            if let peer = peer as? TelegramUser, let inputUser = apiInputUser(peer) {
                return account.network.request(Api.functions.photos.getUserPhotos(userId: inputUser, offset: 0, maxId: 0, limit: 100))
                    |> map {Optional($0)}
                    |> mapError {_ in}
                    |> `catch` {
                        return Signal<Api.photos.Photos?, Void>.single(nil)
                    } |> map { result -> [TelegramPeerPhoto] in
                        
                        if let result = result {
                            let totalCount:Int
                            let photos:[Api.Photo]
                            switch result {
                            case let .photos(data):
                                photos = data.photos
                                totalCount = photos.count
                            case let .photosSlice(data):
                                photos = data.photos
                                totalCount = Int(data.count)
                            }
                            
                            var images:[TelegramPeerPhoto] = []
                            for i in 0 ..< photos.count {
                                let photo = photos[i]
                                let image:TelegramMediaImage
                                let reference: TelegramMediaImageReference
                                switch photo {
                                case let .photo(data):
                                    reference = .cloud(imageId: data.id, accessHash: data.accessHash)
                                    image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: data.id), representations: telegramMediaImageRepresentationsFromApiSizes(data.sizes), reference: reference)
                                case let .photoEmpty(id: id):
                                    reference = .cloud(imageId: id, accessHash: 0)
                                    image = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: id), representations: [], reference: reference)
                                }
                                images.append(TelegramPeerPhoto(image: image, reference: reference, index: i, totalCount: totalCount))
                            }
                            
                            return images
                        } else {
                            return []
                        }
                }
            } else if let peer = peer, let inputPeer = apiInputPeer(peer) {
                return account.network.request(Api.functions.messages.search(flags: 0, peer: inputPeer, q: "", fromId: nil, filter: .inputMessagesFilterChatPhotos, minDate: 0, maxDate: 0, offsetId: 0, addOffset: 0, limit: 1000, maxId: 0, minId: 0)) |> map {Optional($0)}
                    |> mapError {_ in}
                    |> `catch` {
                        return Signal<Api.messages.Messages?, Void>.single(nil)
                    } |> mapToSignal { result -> Signal<[TelegramPeerPhoto], Void> in
                        
                        if let result = result {
                            let messages: [Api.Message]
                            let chats: [Api.Chat]
                            let users: [Api.User]
                            switch result {
                            case let .channelMessages(_, _, _, apiMessages, apiChats, apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                            case let .messages(apiMessages, apiChats, apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                            case let.messagesSlice(_, apiMessages, apiChats, apiUsers):
                                messages = apiMessages
                                chats = apiChats
                                users = apiUsers
                            }
                            
                            return account.postbox.modify { modifier -> [Message] in
                                var peers: [PeerId: Peer] = [:]
                                
                                for user in users {
                                    if let user = TelegramUser.merge(modifier.getPeer(user.peerId) as? TelegramUser, rhs: user) {
                                        peers[user.id] = user
                                    }
                                }
                                
                                for chat in chats {
                                    if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                        peers[groupOrChannel.id] = groupOrChannel
                                    }
                                }
                                
                                var renderedMessages: [Message] = []
                                for message in messages {
                                    if let message = StoreMessage(apiMessage: message), let renderedMessage = locallyRenderedMessage(message: message, peers: peers) {
                                        renderedMessages.append(renderedMessage)
                                    }
                                }
                                
                                return renderedMessages
                            } |> map { messages -> [TelegramPeerPhoto] in
                                var photos:[TelegramPeerPhoto] = []
                                var index:Int = 0
                                for message in messages {
                                    if let media = message.media.first as? TelegramMediaAction {
                                        switch media.action {
                                        case let .photoUpdated(image):
                                            if let image = image {
                                                photos.append(TelegramPeerPhoto(image: image, reference: nil, index: index, totalCount: messages.count))
                                            }
                                        default:
                                            break
                                        }
                                    }
                                    index += 1
                                }
                                return photos
                            }
                            
                        } else {
                            return .single([])
                        }
                }
            } else {
                return .single([])
            }
    }
}
