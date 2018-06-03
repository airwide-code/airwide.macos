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

public func ensuredExistingPeerExportedInvitation(account: Account, peerId: PeerId, revokeExisted: Bool = false) -> Signal<Void, NoError> {
    return account.postbox.modify { modifier -> Signal<Void, NoError> in
        if let peer = modifier.getPeer(peerId) {
            if let channel = peer as? TelegramChannel, let inputChannel = apiInputChannel(channel) {
                if let cachedData = modifier.getPeerCachedData(peerId: peerId) as? CachedChannelData, cachedData.exportedInvitation != nil && !revokeExisted {
                    return .complete()
                } else {
                    return account.network.request(Api.functions.channels.exportInvite(channel: inputChannel))
                        |> retryRequest
                        |> mapToSignal { result -> Signal<Void, NoError> in
                            return account.postbox.modify { modifier -> Void in
                                if let invitation = ExportedInvitation(apiExportedInvite: result) {
                                    modifier.updatePeerCachedData(peerIds: Set([peerId]), update: { _, current in
                                        if let current = current as? CachedChannelData {
                                            return current.withUpdatedExportedInvitation(invitation)
                                        } else {
                                            return current
                                        }
                                    })
                                }
                            }
                        }
                }
            } else if let group = peer as? TelegramGroup {
                if let cachedData = modifier.getPeerCachedData(peerId: peerId) as? CachedGroupData, cachedData.exportedInvitation != nil && !revokeExisted {
                    return .complete()
                } else {
                    return account.network.request(Api.functions.messages.exportChatInvite(chatId: group.id.id))
                        |> retryRequest
                        |> mapToSignal { result -> Signal<Void, NoError> in
                            return account.postbox.modify { modifier -> Void in
                                if let invitation = ExportedInvitation(apiExportedInvite: result) {
                                    modifier.updatePeerCachedData(peerIds: Set([peerId]), update: { _, current in
                                        if let current = current as? CachedGroupData {
                                            return current.withUpdatedExportedInvitation(invitation)
                                        } else {
                                            return current
                                        }
                                    })
                                }
                            }
                    }
                }
            } else {
                return .complete()
            }
        } else {
            return .complete()
        }
    } |> switchToLatest
}
