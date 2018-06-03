import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

final class CachedStickerPack: PostboxCoding {
    let info: StickerPackCollectionInfo?
    let items: [StickerPackItem]
    let hash: Int32
    
    init(info: StickerPackCollectionInfo?, items: [StickerPackItem], hash: Int32) {
        self.info = info
        self.items = items
        self.hash = hash
    }
    
    init(decoder: PostboxDecoder) {
        self.info = decoder.decodeObjectForKey("in", decoder: { StickerPackCollectionInfo(decoder: $0) }) as? StickerPackCollectionInfo
        self.items = decoder.decodeObjectArrayForKey("it").map { $0 as! StickerPackItem }
        self.hash = decoder.decodeInt32ForKey("h", orElse: 0)
    }
    
    func encode(_ encoder: PostboxEncoder) {
        if let info = self.info {
            encoder.encodeObject(info, forKey: "in")
        } else {
            encoder.encodeNil(forKey: "in")
        }
        encoder.encodeObjectArray(self.items, forKey: "it")
        encoder.encodeInt32(self.hash, forKey: "h")
    }
    
    static func cacheKey(_ id: ItemCollectionId) -> ValueBoxKey {
        let key = ValueBoxKey(length: 4 + 8)
        key.setInt32(0, value: id.namespace)
        key.setInt64(4, value: id.id)
        return key
    }
}

private let collectionSpec = ItemCacheCollectionSpec(lowWaterItemCount: 100, highWaterItemCount: 200)

public func cachedStickerPack(postbox: Postbox, network: Network, reference: StickerPackReference) -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem], Bool)?, NoError> {
    return postbox.modify { modifier -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem], Bool)?, NoError> in
        let namespace = Namespaces.ItemCollection.CloudStickerPacks
        if case let .id(id, _) = reference, let currentInfo = modifier.getItemCollectionInfo(collectionId: ItemCollectionId(namespace: namespace, id: id)) as? StickerPackCollectionInfo {
            let items = modifier.getItemCollectionItems(collectionId: ItemCollectionId(namespace: namespace, id: id))
            return .single((currentInfo, items, true))
        } else {
            let current: Signal<(StickerPackCollectionInfo, [ItemCollectionItem], Bool)?, NoError>
            var loadRemote = false
            
            if case let .id(id, _) = reference, let cached = modifier.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedStickerPacks, key: CachedStickerPack.cacheKey(ItemCollectionId(namespace: namespace, id: id)))) as? CachedStickerPack, let info = cached.info {
                current = .single((info, cached.items, false))
                if cached.hash != info.hash {
                    loadRemote = true
                }
            } else {
                current = .single(nil)
                loadRemote = true
            }
            
            var signal = current
            if loadRemote {
                let appliedRemote = remoteStickerPack(network: network, reference: reference)
                    |> mapToSignal { result -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem], Bool)?, NoError> in
                        return postbox.modify { modifier -> (StickerPackCollectionInfo, [ItemCollectionItem], Bool)? in
                            if let result = result {
                                modifier.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedStickerPacks, key: CachedStickerPack.cacheKey(result.0.id)), entry: CachedStickerPack(info: result.0, items: result.1.map { $0 as! StickerPackItem }, hash: result.0.hash), collectionSpec: collectionSpec)
                                
                                let currentInfo = modifier.getItemCollectionInfo(collectionId: result.0.id) as? StickerPackCollectionInfo
                                
                                return (result.0, result.1, currentInfo != nil)
                            } else {
                                return nil
                            }
                        }
                    }
                
                signal = signal |> then(appliedRemote)
            }
            
            return signal
        }
    } |> switchToLatest
}
