import Foundation

public struct NoticeEntryKey: Hashable {
    public let namespace: ValueBoxKey
    public let key: ValueBoxKey
    
    fileprivate let combinedKey: ValueBoxKey
    
    public init(namespace: ValueBoxKey, key: ValueBoxKey) {
        self.namespace = namespace
        self.key = key
        
        let combinedKey = ValueBoxKey(length: namespace.length + key.length)
        memcpy(combinedKey.memory, namespace.memory, namespace.length)
        memcpy(combinedKey.memory.advanced(by: namespace.length), key.memory, key.length)
        self.combinedKey = combinedKey
    }
    
    public static func ==(lhs: NoticeEntryKey, rhs: NoticeEntryKey) -> Bool {
        return lhs.combinedKey == rhs.combinedKey
    }
    
    public var hashValue: Int {
        return self.combinedKey.hashValue
    }
}

private struct CachedEntry {
    let entry: PostboxCoding?
}

final class NoticeTable: Table {
    private var cachedEntries: [NoticeEntryKey: CachedEntry] = [:]
    private var updatedEntryKeys = Set<NoticeEntryKey>()
    
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .binary)
    }
    
    func get(key: NoticeEntryKey) -> PostboxCoding? {
        if let cached = self.cachedEntries[key] {
            return cached.entry
        } else {
            if let value = self.valueBox.get(self.table, key: key.combinedKey), let object = PostboxDecoder(buffer: value).decodeRootObject() {
                self.cachedEntries[key] = CachedEntry(entry: object)
                return object
            } else {
                self.cachedEntries[key] = CachedEntry(entry: nil)
                return nil
            }
        }
    }
    
    func set(key: NoticeEntryKey, value: PostboxCoding?) {
        self.cachedEntries[key] = CachedEntry(entry: value)
        updatedEntryKeys.insert(key)
    }
    
    override func clearMemoryCache() {
        assert(self.updatedEntryKeys.isEmpty)
    }
    
    override func beforeCommit() {
        if !self.updatedEntryKeys.isEmpty {
            for key in self.updatedEntryKeys {
                if let value = self.cachedEntries[key]?.entry {
                    let encoder = PostboxEncoder()
                    encoder.encodeRootObject(value)
                    withExtendedLifetime(encoder, {
                        self.valueBox.set(self.table, key: key.combinedKey, value: encoder.readBufferNoCopy())
                    })
                } else {
                    self.valueBox.remove(self.table, key: key.combinedKey)
                }
            }
            
            self.updatedEntryKeys.removeAll()
        }
    }
}
