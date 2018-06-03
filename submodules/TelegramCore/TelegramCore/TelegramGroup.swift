import Foundation
#if os(macOS)
    import PostboxMac
#else
    import Postbox
#endif

public enum TelegramGroupRole: Int32 {
    case creator
    case admin
    case member
}

public enum TelegramGroupMembership: Int32 {
    case Member
    case Left
    case Removed
}

public struct TelegramGroupFlags: OptionSet {
    public var rawValue: Int32
    
    public init() {
        self.rawValue = 0
    }
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public static let adminsEnabled = TelegramGroupFlags(rawValue: 1 << 0)
    public static let deactivated = TelegramGroupFlags(rawValue: 1 << 1)
}

public struct TelegramGroupToChannelMigrationReference: Equatable {
    public let peerId: PeerId
    public let accessHash: Int64
    
    public static func ==(lhs: TelegramGroupToChannelMigrationReference, rhs: TelegramGroupToChannelMigrationReference) -> Bool {
        return lhs.peerId == rhs.peerId && lhs.accessHash == rhs.accessHash
    }
}

public final class TelegramGroup: Peer {
    public let id: PeerId
    public let title: String
    public let photo: [TelegramMediaImageRepresentation]
    public let participantCount: Int
    public let role: TelegramGroupRole
    public let membership: TelegramGroupMembership
    public let flags: TelegramGroupFlags
    public let migrationReference: TelegramGroupToChannelMigrationReference?
    public let creationDate: Int32
    public let version: Int
    
    public var indexName: PeerIndexNameRepresentation {
        return .title(title: self.title, addressName: nil)
    }
    
    public let associatedPeerId: PeerId? = nil
    public let notificationSettingsPeerId: PeerId? = nil
    
    public init(id: PeerId, title: String, photo: [TelegramMediaImageRepresentation], participantCount: Int, role: TelegramGroupRole, membership: TelegramGroupMembership, flags: TelegramGroupFlags, migrationReference: TelegramGroupToChannelMigrationReference?, creationDate: Int32, version: Int) {
        self.id = id
        self.title = title
        self.photo = photo
        self.participantCount = participantCount
        self.role = role
        self.membership = membership
        self.flags = flags
        self.migrationReference = migrationReference
        self.creationDate = creationDate
        self.version = version
    }
    
    public init(decoder: PostboxDecoder) {
        self.id = PeerId(decoder.decodeInt64ForKey("i", orElse: 0))
        self.title = decoder.decodeStringForKey("t", orElse: "")
        self.photo = decoder.decodeObjectArrayForKey("ph")
        self.participantCount = Int(decoder.decodeInt32ForKey("pc", orElse: 0))
        self.role = TelegramGroupRole(rawValue: decoder.decodeInt32ForKey("r", orElse: 0))!
        self.membership = TelegramGroupMembership(rawValue: decoder.decodeInt32ForKey("m", orElse: 0))!
        self.flags = TelegramGroupFlags(rawValue: decoder.decodeInt32ForKey("f", orElse: 0))
        let migrationPeerId: Int64? = decoder.decodeOptionalInt64ForKey("mr.i")
        let migrationAccessHash: Int64? = decoder.decodeOptionalInt64ForKey("mr.a")
        if let migrationPeerId = migrationPeerId, let migrationAccessHash = migrationAccessHash {
            self.migrationReference = TelegramGroupToChannelMigrationReference(peerId: PeerId(migrationPeerId), accessHash: migrationAccessHash)
        } else {
            self.migrationReference = nil
        }
        self.creationDate = decoder.decodeInt32ForKey("d", orElse: 0)
        self.version = Int(decoder.decodeInt32ForKey("v", orElse: 0))
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt64(self.id.toInt64(), forKey: "i")
        encoder.encodeString(self.title, forKey: "t")
        encoder.encodeObjectArray(self.photo, forKey: "ph")
        encoder.encodeInt32(Int32(self.participantCount), forKey: "pc")
        encoder.encodeInt32(self.role.rawValue, forKey: "r")
        encoder.encodeInt32(self.membership.rawValue, forKey: "m")
        if let migrationReference = self.migrationReference {
            encoder.encodeInt64(migrationReference.peerId.toInt64(), forKey: "mr.i")
            encoder.encodeInt64(migrationReference.accessHash, forKey: "mr.a")
        } else {
            encoder.encodeNil(forKey: "mr.i")
            encoder.encodeNil(forKey: "mr.a")
        }
        encoder.encodeInt32(self.creationDate, forKey: "d")
        encoder.encodeInt32(Int32(self.version), forKey: "v")
    }
    
    public func isEqual(_ other: Peer) -> Bool {
        if let other = other as? TelegramGroup {
            if self.id != other.id {
                return false
            }
            if self.title != other.title {
                return false
            }
            if self.photo != other.photo {
                return false
            }
            if self.membership != other.membership {
                return false
            }
            if self.version != other.version {
                return false
            }
            if self.participantCount != other.participantCount {
                return false
            }
            if self.role != other.role {
                return false
            }
            if self.migrationReference != other.migrationReference {
                return false
            }
            if self.creationDate != other.creationDate {
                return false
            }
            if self.flags != other.flags {
                return false
            }
            return true
        } else {
            return false
        }
    }

    public func updateFlags(flags: TelegramGroupFlags, version: Int) -> TelegramGroup {
        return TelegramGroup(id: self.id, title: self.title, photo: self.photo, participantCount: self.participantCount, role: self.role, membership: self.membership, flags: flags, migrationReference: self.migrationReference, creationDate: self.creationDate, version: version)
    }
}
