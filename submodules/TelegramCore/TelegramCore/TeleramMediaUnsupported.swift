import Foundation
#if os(macOS)
    import PostboxMac
#else
    import Postbox
#endif

public final class TelegramMediaUnsupported: Media {
    public let id: MediaId? = nil
    public let peerIds: [PeerId] = []
    
    init() {
    }
    
    public init(decoder: PostboxDecoder) {
    }
    
    public func encode(_ encoder: PostboxEncoder) {
    }
    
    public func isEqual(_ other: Media) -> Bool {
        if other is TelegramMediaUnsupported {
            return true
        }
        return false
    }
}
