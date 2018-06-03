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

public func requestBlockedPeers(account: Account) -> Signal<[Peer], NoError> {
    return account.network.request(Api.functions.contacts.getBlocked(offset: 0, limit: 100))
        |> retryRequest
        |> mapToSignal { result -> Signal<[Peer], NoError> in
            return account.postbox.modify { modifier -> [Peer] in
                var peers: [Peer] = []
                let apiUsers: [Api.User]
                switch result {
                    case let .blocked(_, users):
                        apiUsers = users
                    case let .blockedSlice(_, _, users):
                        apiUsers = users
                }
                for user in apiUsers {
                    let parsed = TelegramUser(user: user)
                    peers.append(parsed)
                }
                
                updatePeers(modifier: modifier, peers: peers, update: { _, updated in
                    return updated
                })
                
                return peers
            }
        }
}

public func requestUpdatePeerIsBlocked(account: Account, peerId: PeerId, isBlocked: Bool) -> Signal<Void, NoError> {
    return account.postbox.modify { modifier -> Signal<Void, NoError> in
        if let peer = modifier.getPeer(peerId), let inputUser = apiInputUser(peer) {
            let signal: Signal<Api.Bool, MTRpcError>
            if isBlocked {
                signal = account.network.request(Api.functions.contacts.block(id: inputUser))
            } else {
                signal = account.network.request(Api.functions.contacts.unblock(id: inputUser))
            }
            return signal
                |> map { Optional($0) }
                |> `catch` { _ -> Signal<Api.Bool?, NoError> in
                    return .single(nil)
                }
                |> mapToSignal { result -> Signal<Void, NoError> in
                    return account.postbox.modify { modifier -> Void in
                        if result != nil {
                            modifier.updatePeerCachedData(peerIds: Set([peerId]), update: { _, current in
                                let previous: CachedUserData
                                if let current = current as? CachedUserData {
                                    previous = current
                                } else {
                                    previous = CachedUserData()
                                }
                                return previous.withUpdatedIsBlocked(isBlocked)
                            })
                        }
                    }
                }
        } else {
            return .complete()
        }
    } |> switchToLatest
}
