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

public func toggleShouldChannelMessagesSignatures(account:Account, peerId:PeerId, enabled: Bool) -> Signal<Void, Void> {
    return account.postbox.modify { modifier -> Signal<Void, Void> in
        if let peer = modifier.getPeer(peerId) as? TelegramChannel, let inputChannel = apiInputChannel(peer) {
            return account.network.request(Api.functions.channels.toggleSignatures(channel: inputChannel, enabled: enabled ? .boolTrue : .boolFalse)) |> retryRequest |> map { updates -> Void in
                account.stateManager.addUpdates(updates)
            }
        } else {
            return .complete()
        }
    } |> switchToLatest
}
