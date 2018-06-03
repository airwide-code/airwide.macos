import Foundation

public protocol AccountRecordAttribute: PostboxCoding {
    func isEqual(to: AccountRecordAttribute) -> Bool
}

public struct AccountRecordId: Comparable, Hashable {
    let rawValue: Int64
    
    init(rawValue: Int64) {
        self.rawValue = rawValue
    }
    
    public var int64: Int64 {
        return self.rawValue
    }
    
    public var hashValue: Int {
        return self.rawValue.hashValue
    }
    
    public static func ==(lhs: AccountRecordId, rhs: AccountRecordId) -> Bool {
        return lhs.rawValue == rhs.rawValue
    }
    
    public static func <(lhs: AccountRecordId, rhs: AccountRecordId) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

public func generateAccountRecordId() -> AccountRecordId {
    var id: Int64 = 0
    arc4random_buf(&id, 8)
    return AccountRecordId(rawValue: id)
}

public struct AccountRecord: PostboxCoding, Equatable {
    public let id: AccountRecordId
    public let attributes: [AccountRecordAttribute]
    
    public init(id: AccountRecordId, attributes: [AccountRecordAttribute]) {
        self.id = id
        self.attributes = attributes
    }
    
    public init(decoder: PostboxDecoder) {
        self.id = AccountRecordId(rawValue: decoder.decodeInt64ForKey("id", orElse: 0))
        self.attributes = (decoder.decodeObjectArrayForKey("attributes") as [PostboxCoding]).map { $0 as! AccountRecordAttribute }
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt64(self.id.int64, forKey: "id")
        let attributes: [PostboxCoding] = self.attributes.map { $0 }
        encoder.encodeGenericObjectArray(attributes, forKey: "attributes")
    }
    
    public static func ==(lhs: AccountRecord, rhs: AccountRecord) -> Bool {
        if lhs.id != rhs.id {
            return false
        }
        if lhs.attributes.count != rhs.attributes.count {
            return false
        }
        for i in 0 ..< lhs.attributes.count {
            if !lhs.attributes[i].isEqual(to: rhs.attributes[i]) {
                return false
            }
        }
        return true
    }
}
