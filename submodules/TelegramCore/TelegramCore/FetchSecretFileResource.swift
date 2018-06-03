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

func fetchSecretFileResource(account: Account, resource: SecretFileMediaResource, range: Range<Int>, tag: MediaResourceFetchTag?) -> Signal<MediaResourceDataFetchResult, NoError> {
    return multipartFetch(account: account, resource: resource, size: resource.size, range: range, tag: tag, encryptionKey: resource.key, decryptedSize: resource.decryptedSize)
}
