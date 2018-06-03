import Foundation
#if os(macOS)
    import PostboxMac
#else
    import Postbox
#endif

public enum LocalizationEntry: Equatable {
    case string(key: String, value: String)
    case pluralizedString(key: String, zero: String?, one: String?, two: String?, few: String?, many: String?, other: String)
    
    public var key: String {
        switch self {
            case let .string(key, _):
                return key
            case let .pluralizedString(key, _, _, _, _, _, _):
                return key
        }
    }
    
    public static func ==(lhs: LocalizationEntry, rhs: LocalizationEntry) -> Bool {
        switch lhs {
            case let .string(lhsKey, lhsValue):
                if case let .string(rhsKey, rhsValue) = rhs, lhsKey == rhsKey, lhsValue == rhsValue {
                    return true
                } else {
                    return false
                }
            case let .pluralizedString(lhsKey, lhsZero, lhsOne, lhsTwo, lhsFew, lhsMany, lhsOther):
                if case let .pluralizedString(rhsKey, rhsZero, rhsOne, rhsTwo, rhsFew, rhsMany, rhsOther) = rhs {
                    if lhsKey != rhsKey {
                        return false
                    }
                    if lhsZero != rhsZero {
                        return false
                    }
                    if lhsOne != rhsOne {
                        return false
                    }
                    if lhsTwo != rhsTwo {
                        return false
                    }
                    if lhsFew != rhsFew {
                        return false
                    }
                    if lhsMany != rhsMany {
                        return false
                    }
                    if lhsOther != rhsOther {
                        return false
                    }
                    return true
                } else {
                    return false
                }
        }
    }
}

private struct LocalizationEntryFlags: OptionSet {
    var rawValue: Int8
    
    init(rawValue: Int8) {
        self.rawValue = rawValue
    }
    
    init() {
        self.rawValue = 0
    }
    
    static let pluralized = LocalizationEntryFlags(rawValue: (1 << 0))
    static let hasZero = LocalizationEntryFlags(rawValue: (1 << 1))
    static let hasOne = LocalizationEntryFlags(rawValue: (1 << 2))
    static let hasTwo = LocalizationEntryFlags(rawValue: (1 << 3))
    static let hasFew = LocalizationEntryFlags(rawValue: (1 << 4))
    static let hasMany = LocalizationEntryFlags(rawValue: (1 << 5))
}

private func writeString(_ buffer: WriteBuffer, _ string: String) {
    if let data = string.data(using: .utf8) {
        var length: Int32 = Int32(data.count)
        buffer.write(&length, offset: 0, length: 4)
        buffer.write(data)
    } else {
        var length: Int32 = 0
        buffer.write(&length, offset: 0, length: 4)
    }
}

public final class Localization: PostboxCoding, Equatable {
    public let version: Int32
    public let entries: [LocalizationEntry]
    
    init(version: Int32, entries: [LocalizationEntry]) {
        self.version = version
        self.entries = entries
    }
    
    public init(decoder: PostboxDecoder) {
        self.version = decoder.decodeInt32ForKey("v", orElse: 0)
        let count = decoder.decodeInt32ForKey("c", orElse: 0)
        var entries: [LocalizationEntry] = []
        if let data = decoder.decodeBytesForKey("d") {
            for _ in 0 ..< count {
                var flagsValue: Int8 = 0
                data.read(&flagsValue, offset: 0, length: 1)
                let flags = LocalizationEntryFlags(rawValue: flagsValue)
                
                var length: Int32 = 0
                data.read(&length, offset: 0, length: 4)
                
                let keyData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                let key = String(data: keyData, encoding: .utf8)
                data.skip(Int(length))
                
                if flags.contains(.pluralized) {
                    var zero: String?
                    var one: String?
                    var two: String?
                    var few: String?
                    var many: String?
                    var other: String?
                    
                    if flags.contains(.hasZero) {
                        length = 0
                        data.read(&length, offset: 0, length: 4)
                        let valueData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                        let value = String(data: valueData, encoding: .utf8)
                        data.skip(Int(length))
                        zero = value
                    }
                    
                    if flags.contains(.hasOne) {
                        length = 0
                        data.read(&length, offset: 0, length: 4)
                        let valueData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                        let value = String(data: valueData, encoding: .utf8)
                        data.skip(Int(length))
                        one = value
                    }
                    
                    if flags.contains(.hasTwo) {
                        length = 0
                        data.read(&length, offset: 0, length: 4)
                        let valueData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                        let value = String(data: valueData, encoding: .utf8)
                        data.skip(Int(length))
                        two = value
                    }
                    
                    if flags.contains(.hasFew) {
                        length = 0
                        data.read(&length, offset: 0, length: 4)
                        let valueData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                        let value = String(data: valueData, encoding: .utf8)
                        data.skip(Int(length))
                        few = value
                    }
                    
                    if flags.contains(.hasMany) {
                        length = 0
                        data.read(&length, offset: 0, length: 4)
                        let valueData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                        let value = String(data: valueData, encoding: .utf8)
                        data.skip(Int(length))
                        many = value
                    }
                    
                    length = 0
                    data.read(&length, offset: 0, length: 4)
                    let valueData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                    let value = String(data: valueData, encoding: .utf8)
                    data.skip(Int(length))
                    other = value
                    
                    if let key = key, let other = other {
                        entries.append(.pluralizedString(key: key, zero: zero, one: one, two: two, few: few, many: many, other: other))
                    }
                } else {
                    length = 0
                    data.read(&length, offset: 0, length: 4)
                    let valueData = Data(bytes: data.memory.advanced(by: data.offset), count: Int(length))
                    let value = String(data: valueData, encoding: .utf8)
                    data.skip(Int(length))
                    
                    if let key = key, let value = value {
                        entries.append(.string(key: key, value: value))
                    }
                }
            }
        }
        self.entries = entries
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(Int32(self.entries.count), forKey: "c")
        
        let buffer = WriteBuffer()
        for entry in self.entries {
            var flags: LocalizationEntryFlags = []
            switch entry {
                case .string:
                    flags = []
                case let .pluralizedString(_, zero, one, two, few, many, _):
                    flags.insert(.pluralized)
                    if zero != nil {
                        flags.insert(.hasZero)
                    }
                    if one != nil {
                        flags.insert(.hasOne)
                    }
                    if two != nil {
                        flags.insert(.hasTwo)
                    }
                    if few != nil {
                        flags.insert(.hasFew)
                    }
                    if many != nil {
                        flags.insert(.hasMany)
                    }
            }
            var flagsValue: Int8 = flags.rawValue
            buffer.write(&flagsValue, offset: 0, length: 1)
            
            switch entry {
                case let .string(key, value):
                    writeString(buffer, key)
                    writeString(buffer, value)
                case let .pluralizedString(key, zero, one, two, few, many, other):
                    writeString(buffer, key)
                    if let zero = zero {
                        writeString(buffer, zero)
                    }
                    if let one = one {
                        writeString(buffer, one)
                    }
                    if let two = two {
                        writeString(buffer, two)
                    }
                    if let few = few {
                        writeString(buffer, few)
                    }
                    if let many = many {
                        writeString(buffer, many)
                    }
                    writeString(buffer, other)
            }
        }
        encoder.encodeBytes(buffer, forKey: "d")
    }
    
    public static func ==(lhs: Localization, rhs: Localization) -> Bool {
        if lhs === rhs {
            return true
        }
        if lhs.entries == rhs.entries {
            return true
        }
        return false
    }
}