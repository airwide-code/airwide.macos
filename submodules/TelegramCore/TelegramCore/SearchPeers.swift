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

public struct FoundPeer: Equatable {
    public let peer: Peer
    public let subscribers: Int32?
    
    init(peer: Peer, subscribers: Int32?) {
        self.peer = peer
        self.subscribers = subscribers
    }
    
    public static func ==(lhs: FoundPeer, rhs: FoundPeer) -> Bool {
        return lhs.peer.isEqual(rhs.peer) && lhs.subscribers == rhs.subscribers
    }
}

public func searchPeers(account: Account, query: String) -> Signal<[FoundPeer], NoError> {
    let searchResult = account.network.request(Api.functions.contacts.search(q: query, limit: 10))
        |> map { Optional($0) }
        |> `catch` { _ in
            return Signal<Api.contacts.Found?, NoError>.single(nil)
        }
    let processedSearchResult = searchResult
        |> mapToSignal { result -> Signal<[FoundPeer], NoError> in
            if let result = result {
                switch result {
                case let .found(results, chats, users):
                    return account.postbox.modify { modifier -> [FoundPeer] in
                        var peers: [PeerId: Peer] = [:]
                        var subscribres:[PeerId : Int32] = [:]
                        for user in users {
                            if let user = TelegramUser.merge(modifier.getPeer(user.peerId) as? TelegramUser, rhs: user) {
                                peers[user.id] = user
                            }
                        }
                        
                        
                        
                        for chat in chats {
                            if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                peers[groupOrChannel.id] = groupOrChannel
                                switch chat {
                                case let .channel(_, _, _, _, _, _, _, _, _, _, _, participantsCount):
                                    if let participantsCount = participantsCount {
                                        subscribres[groupOrChannel.id] = participantsCount
                                    }
                                default:
                                    break
                                }
                            }
                        }
                        
                        var renderedPeers: [FoundPeer] = []
                        for result in results {
                            let peerId: PeerId
                            switch result {
                            case let .peerUser(userId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                            case let .peerChat(chatId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                            case let .peerChannel(channelId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                            }
                            if let peer = peers[peerId] {
                                renderedPeers.append(FoundPeer(peer: peer, subscribers: subscribres[peerId]))
                            }
                        }
                        
                        return renderedPeers
                    }
                }
            } else {
                return .single([])
            }
            
    }
    
    return processedSearchResult
}
