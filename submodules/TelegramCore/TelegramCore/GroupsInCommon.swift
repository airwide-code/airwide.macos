import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

public func groupsInCommon(account:Account, peerId:PeerId) -> Signal<[PeerId], Void> {
    return account.postbox.modify { modifier -> Signal<[PeerId], Void> in
        if let peer = modifier.getPeer(peerId), let inputUser = apiInputUser(peer) {
            return account.network.request(Api.functions.messages.getCommonChats(userId: inputUser, maxId: 0, limit: 100)) |> mapError {_ in}  |> mapToSignal {  result -> Signal<[PeerId], Void> in
                let chats:[Api.Chat]
                switch result {
                case let .chats(chats: apiChats):
                    chats = apiChats
                case let .chatsSlice(count: _, chats: apiChats):
                    chats = apiChats
                }
                
                return account.postbox.modify { modifier -> [PeerId] in
                    var peers:[Peer] = []
                    for chat in chats {
                        if let peer = parseTelegramGroupOrChannel(chat: chat) {
                            peers.append(peer)
                        }
                    }
                    updatePeers(modifier: modifier, peers: peers, update: { _, updated -> Peer? in
                        return updated
                    })
                    return peers.map {$0.id}
                }
            }
        } else {
            return .single([])
        }
    } |> switchToLatest
}
