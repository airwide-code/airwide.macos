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

public func channelAdmins(account: Account, peerId: PeerId) -> Signal<[RenderedChannelParticipant], NoError> {
    return account.postbox.modify { modifier -> Signal<[RenderedChannelParticipant], NoError> in
        if let peer = modifier.getPeer(peerId), let inputChannel = apiInputChannel(peer) {
            return account.network.request(Api.functions.channels.getParticipants(channel: inputChannel, filter: .channelParticipantsAdmins, offset: 0, limit: 100, hash: 0))
                |> retryRequest
                |> mapToSignal { result -> Signal<[RenderedChannelParticipant], NoError> in
                    switch result {
                        case let .channelParticipants(count, participants, users):
                            var items: [RenderedChannelParticipant] = []
                            
                            var peers: [PeerId: Peer] = [:]
                            var presences:[PeerId: PeerPresence] = [:]
                            for user in users {
                                let peer = TelegramUser(user: user)
                                peers[peer.id] = peer
                                if let presence = TelegramUserPresence(apiUser: user) {
                                    presences[peer.id] = presence
                                }
                            }
                            
                            for participant in CachedChannelParticipants(apiParticipants: participants).participants {
                                if let peer = peers[participant.peerId] {
                                    items.append(RenderedChannelParticipant(participant: participant, peer: peer, peers: peers, presences: presences))
                                }
                                
                            }
                        
                            return account.postbox.modify { modifier -> [RenderedChannelParticipant] in
                                modifier.updatePeerCachedData(peerIds: Set([peerId]), update: { _, cachedData -> CachedPeerData? in
                                    if let cachedData = cachedData as? CachedChannelData {
                                        return cachedData.withUpdatedParticipantsSummary(cachedData.participantsSummary.withUpdatedAdminCount(count))
                                    } else {
                                        return cachedData
                                    }
                                })
                                return items
                            }
                        case .channelParticipantsNotModified:
                            return .single([])
                    }
                }
        } else {
            return .single([])
        }
    } |> switchToLatest
}
