import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

public enum PeerCacheUsageCategory: Int32 {
    case image = 0
    case video
    case audio
    case file
}

public struct CacheUsageStats {
    public let media: [PeerId: [PeerCacheUsageCategory: [MediaId: Int64]]]
    public let mediaResourceIds: [MediaId: [MediaResourceId]]
    public let peers: [PeerId: Peer]
    
    public init(media: [PeerId: [PeerCacheUsageCategory: [MediaId: Int64]]], mediaResourceIds: [MediaId: [MediaResourceId]], peers: [PeerId: Peer]) {
        self.media = media
        self.mediaResourceIds = mediaResourceIds
        self.peers = peers
    }
}

public enum CacheUsageStatsResult {
    case progress(Float)
    case result(CacheUsageStats)
}

private enum CollectCacheUsageStatsError {
    case done(CacheUsageStats)
}

private final class CacheUsageStatsState {
    var media: [PeerId: [PeerCacheUsageCategory: [MediaId: Int64]]] = [:]
    var mediaResourceIds: [MediaId: [MediaResourceId]] = [:]
    var lowerBound: MessageIndex?
}

public func collectCacheUsageStats(account: Account) -> Signal<CacheUsageStatsResult, NoError> {
    let state = Atomic<CacheUsageStatsState>(value: CacheUsageStatsState())
    
    let fetch = account.postbox.modify { modifier -> ([PeerId : Set<MediaId>], [MediaId : Media], MessageIndex?) in
        return modifier.enumerateMedia(lowerBound: state.with { $0.lowerBound }, limit: 1000)
    } |> mapError { _ -> CollectCacheUsageStatsError in preconditionFailure() }
    
    let process: ([PeerId : Set<MediaId>], [MediaId : Media], MessageIndex?) -> Signal<CacheUsageStatsResult, CollectCacheUsageStatsError> = { mediaByPeer, mediaRefs, updatedLowerBound in
        var mediaIdToPeerId: [MediaId: PeerId] = [:]
        for (peerId, mediaIds) in mediaByPeer {
            for id in mediaIds {
                mediaIdToPeerId[id] = peerId
            }
        }
        
        var resourceIdToMediaId: [WrappedMediaResourceId: (MediaId, PeerCacheUsageCategory)] = [:]
        var mediaResourceIds: [MediaId: [MediaResourceId]] = [:]
        var resourceIds: [MediaResourceId] = []
        for (id, media) in mediaRefs {
            mediaResourceIds[id] = []
            switch media {
                case let image as TelegramMediaImage:
                    for representation in image.representations {
                        resourceIds.append(representation.resource.id)
                        resourceIdToMediaId[WrappedMediaResourceId(representation.resource.id)] = (id, .image)
                        mediaResourceIds[id]!.append(representation.resource.id)
                    }
                case let file as TelegramMediaFile:
                    var category: PeerCacheUsageCategory = .file
                    loop: for attribute in file.attributes {
                        switch attribute {
                            case .Video:
                                category = .video
                                break loop
                            case .Audio:
                                category = .audio
                                break loop
                            default:
                                break
                        }
                    }
                    for representation in file.previewRepresentations {
                        resourceIds.append(representation.resource.id)
                        resourceIdToMediaId[WrappedMediaResourceId(representation.resource.id)] = (id, category)
                        mediaResourceIds[id]!.append(representation.resource.id)
                    }
                    resourceIds.append(file.resource.id)
                    resourceIdToMediaId[WrappedMediaResourceId(file.resource.id)] = (id, category)
                    mediaResourceIds[id]!.append(file.resource.id)
                default:
                    break
            }
        }
        return account.postbox.mediaBox.collectResourceCacheUsage(resourceIds)
            |> mapError { _ -> CollectCacheUsageStatsError in preconditionFailure() }
            |> mapToSignal { result -> Signal<CacheUsageStatsResult, CollectCacheUsageStatsError> in
                state.with { state -> Void in
                    state.lowerBound = updatedLowerBound
                    for (wrappedId, size) in result {
                        if let (id, category) = resourceIdToMediaId[wrappedId] {
                            if let peerId = mediaIdToPeerId[id] {
                                if state.media[peerId] == nil {
                                    state.media[peerId] = [:]
                                }
                                if state.media[peerId]![category] == nil {
                                    state.media[peerId]![category] = [:]
                                }
                                var currentSize: Int64 = 0
                                if let current = state.media[peerId]![category]![id] {
                                    currentSize = current
                                }
                                state.media[peerId]![category]![id] = currentSize + size
                            }
                        }
                    }
                    for (id, ids) in mediaResourceIds {
                        state.mediaResourceIds[id] = ids
                    }
                }
                if updatedLowerBound == nil {
                    let (finalMedia, finalMediaResourceIds) = state.with { state -> ([PeerId: [PeerCacheUsageCategory: [MediaId: Int64]]], [MediaId: [MediaResourceId]]) in
                        return (state.media, state.mediaResourceIds)
                    }
                    return account.postbox.modify { modifier -> CacheUsageStats in
                        var peers: [PeerId: Peer] = [:]
                        for peerId in finalMedia.keys {
                            if let peer = modifier.getPeer(peerId) {
                                peers[peer.id] = peer
                            }
                        }
                        return CacheUsageStats(media: finalMedia, mediaResourceIds: finalMediaResourceIds, peers: peers)
                    } |> mapError { _ -> CollectCacheUsageStatsError in preconditionFailure() }
                    |> mapToSignal { stats -> Signal<CacheUsageStatsResult, CollectCacheUsageStatsError> in
                        return .fail(.done(stats))
                    }
                } else {
                    return .complete()
                }
            }
    }
    
    let signal = (fetch |> mapToSignal { mediaByPeer, mediaRefs, updatedLowerBound -> Signal<CacheUsageStatsResult, CollectCacheUsageStatsError> in
        return process(mediaByPeer, mediaRefs, updatedLowerBound)
    }) |> restart
    
    return signal |> `catch` { error in
        switch error {
            case let .done(result):
                return .single(.result(result))
        }
    }
}

public func clearCachedMediaResources(account: Account, mediaResourceIds: Set<WrappedMediaResourceId>) -> Signal<Void, NoError> {
    return account.postbox.mediaBox.removeCachedResources(mediaResourceIds)
}
