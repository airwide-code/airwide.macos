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

public enum TwoStepVerificationConfiguration {
    case notSet(pendingEmailPattern: String)
    case set(hint: String, hasRecoveryEmail: Bool, pendingEmailPattern: String)
}

public func twoStepVerificationConfiguration(account: Account) -> Signal<TwoStepVerificationConfiguration, NoError> {
    return account.network.request(Api.functions.account.getPassword())
        |> retryRequest
        |> map { result -> TwoStepVerificationConfiguration in
            switch result {
                case let .noPassword(_, emailUnconfirmedPattern):
                    return .notSet(pendingEmailPattern: emailUnconfirmedPattern)
                case let .password(_, _, hint, hasRecovery, emailUnconfirmedPattern):
                    return .set(hint: hint, hasRecoveryEmail: hasRecovery == .boolTrue, pendingEmailPattern: emailUnconfirmedPattern)
            }
        }
}

public struct TwoStepVerificationSettings {
    public let email: String
}

public func requestTwoStepVerifiationSettings(account: Account, password: String) -> Signal<TwoStepVerificationSettings, AuthorizationPasswordVerificationError> {
    return twoStepAuthData(account.network)
        |> mapToSignal { authData -> Signal<TwoStepVerificationSettings, MTRpcError> in
            var data = Data()
            data.append(authData.currentSalt!)
            data.append(password.data(using: .utf8, allowLossyConversion: true)!)
            data.append(authData.currentSalt!)
            let currentPasswordHash = sha256Digest(data)
            
            return account.network.request(Api.functions.account.getPasswordSettings(currentPasswordHash: Buffer(data: currentPasswordHash)), automaticFloodWait: false)
                |> map { result -> TwoStepVerificationSettings in
                    switch result {
                        case let .passwordSettings(email):
                            return TwoStepVerificationSettings(email: email)
                    }
                }
        }
        |> `catch` { error -> Signal<TwoStepVerificationSettings, AuthorizationPasswordVerificationError> in
            if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                return .fail(.limitExceeded)
            } else if error.errorDescription == "PASSWORD_HASH_INVALID" {
                return .fail(.invalidPassword)
            } else {
                return .fail(.generic)
            }
        }
}

public enum UpdateTwoStepVerificationPasswordError {
    case generic
    case invalidEmail
}

public enum UpdateTwoStepVerificationPasswordResult {
    case none
    case password(password: String, pendingEmailPattern: String?)
}

public enum UpdatedTwoStepVerificationPassword {
    case none
    case password(password: String, hint: String, email: String?)
}

public func updateTwoStepVerificationPassword(account: Account, currentPassword: String?, updatedPassword: UpdatedTwoStepVerificationPassword) -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> {
    return twoStepAuthData(account.network)
        |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
            return .generic
        }
        |> mapToSignal { authData -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> in
            let currentPasswordHash: Buffer
            if let currentSalt = authData.currentSalt {
                var data = Data()
                data.append(currentSalt)
                if let currentPassword = currentPassword {
                    data.append(currentPassword.data(using: .utf8, allowLossyConversion: true)!)
                }
                data.append(currentSalt)
                currentPasswordHash = Buffer(data: sha256Digest(data))
            } else {
                currentPasswordHash = Buffer(data: Data())
            }
            
            switch updatedPassword {
                case .none:
                    var flags: Int32 = (1 << 1)
                    if authData.currentSalt != nil {
                        flags |= (1 << 0)
                    }
                    
                    return account.network.request(Api.functions.account.updatePasswordSettings(currentPasswordHash: currentPasswordHash, newSettings: .passwordInputSettings(flags: flags, newSalt: Buffer(data: Data()), newPasswordHash: Buffer(data: Data()), hint: "", email: "")), automaticFloodWait: false)
                        |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
                            return .generic
                        }
                        |> map { _ -> UpdateTwoStepVerificationPasswordResult in
                            return .none
                        }
                case let .password(password, hint, email):
                    var flags: Int32 = 1 << 0
                    if email != nil {
                        flags |= (1 << 1)
                    }
                    
                    var nextSalt = authData.nextSalt
                    var randomSalt = Data()
                    randomSalt.count = 32
                    randomSalt.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) -> Void in
                        arc4random_buf(bytes, 32)
                    }
                    nextSalt.append(randomSalt)
                    
                    var updatedData = Data()
                    updatedData.append(nextSalt)
                    updatedData.append(password.data(using: .utf8, allowLossyConversion: true)!)
                    updatedData.append(nextSalt)
                    
                    let updatedPasswordHash = sha256Digest(updatedData)
                    return account.network.request(Api.functions.account.updatePasswordSettings(currentPasswordHash: currentPasswordHash, newSettings: Api.account.PasswordInputSettings.passwordInputSettings(flags: flags, newSalt: Buffer(data: nextSalt), newPasswordHash: Buffer(data: updatedPasswordHash), hint: hint, email: email)), automaticFloodWait: false)
                        |> map { _ -> UpdateTwoStepVerificationPasswordResult in
                            return .password(password: password, pendingEmailPattern: nil)
                        }
                        |> `catch` { error -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
                            if error.errorDescription == "EMAIL_UNCONFIRMED" {
                                return twoStepAuthData(account.network)
                                    |> map { result -> UpdateTwoStepVerificationPasswordResult in
                                        return .password(password: password, pendingEmailPattern: result.unconfirmedEmailPattern)
                                    }
                            } else {
                                return .fail(error)
                            }
                        }
                        |> mapError { error -> UpdateTwoStepVerificationPasswordError in
                            if error.errorDescription == "EMAIL_INVALID" {
                                return .invalidEmail
                            } else {
                                return .generic
                            }
                        }
            }
        }
}

public func updateTwoStepVerificationEmail(account: Account, currentPassword: String, updatedEmail: String) -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> {
    return twoStepAuthData(account.network)
        |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
            return .generic
        }
        |> mapToSignal { authData -> Signal<UpdateTwoStepVerificationPasswordResult, UpdateTwoStepVerificationPasswordError> in
            let currentPasswordHash: Buffer
            if let currentSalt = authData.currentSalt {
                var data = Data()
                data.append(currentSalt)
                data.append(currentPassword.data(using: .utf8, allowLossyConversion: true)!)
                data.append(currentSalt)
                currentPasswordHash = Buffer(data: sha256Digest(data))
            } else {
                currentPasswordHash = Buffer(data: Data())
            }

            let flags: Int32 = 1 << 1
            return account.network.request(Api.functions.account.updatePasswordSettings(currentPasswordHash: currentPasswordHash, newSettings: Api.account.PasswordInputSettings.passwordInputSettings(flags: flags, newSalt: nil, newPasswordHash: nil, hint: nil, email: updatedEmail)), automaticFloodWait: false)
                |> map { _ -> UpdateTwoStepVerificationPasswordResult in
                    return .password(password: currentPassword, pendingEmailPattern: nil)
                }
                |> `catch` { error -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
                    if error.errorDescription == "EMAIL_UNCONFIRMED" {
                        return twoStepAuthData(account.network)
                            |> map { result -> UpdateTwoStepVerificationPasswordResult in
                                return .password(password: currentPassword, pendingEmailPattern: result.unconfirmedEmailPattern)
                        }
                    } else {
                        return .fail(error)
                    }
                }
                |> mapError { error -> UpdateTwoStepVerificationPasswordError in
                    if error.errorDescription == "EMAIL_INVALID" {
                        return .invalidEmail
                    } else {
                        return .generic
                    }
                }
    }
}

public enum RequestTwoStepVerificationPasswordRecoveryCodeError {
    case generic
}

public func requestTwoStepVerificationPasswordRecoveryCode(account: Account) -> Signal<String, RequestTwoStepVerificationPasswordRecoveryCodeError> {
    return account.network.request(Api.functions.auth.requestPasswordRecovery(), automaticFloodWait: false)
        |> mapError { _ -> RequestTwoStepVerificationPasswordRecoveryCodeError in
            return .generic
        }
        |> map { result -> String in
            switch result {
                case let .passwordRecovery(emailPattern):
                    return emailPattern
            }
        }
}

public enum RecoverTwoStepVerificationPasswordError {
    case generic
    case codeExpired
    case limitExceeded
    case invalidCode
}

public func recoverTwoStepVerificationPassword(account: Account, code: String) -> Signal<Void, RecoverTwoStepVerificationPasswordError> {
    return account.network.request(Api.functions.auth.recoverPassword(code: code), automaticFloodWait: false)
        |> mapError { error -> RecoverTwoStepVerificationPasswordError in
            if error.errorDescription.hasPrefix("FLOOD_WAIT_") {
                return .limitExceeded
            } else if error.errorDescription == "PASSWORD_RECOVERY_EXPIRED" {
                return .codeExpired
            } else if error.errorDescription == "CODE_INVALID" {
                return .invalidCode
            } else {
                return .generic
            }
        }
        |> mapToSignal { _ -> Signal<Void, RecoverTwoStepVerificationPasswordError> in
            return .complete()
        }
}

public struct TemporaryTwoStepPasswordToken: PostboxCoding, Equatable {
    public let token: Data
    public let validUntilDate: Int32
    public let requiresBiometrics: Bool
    
    public init(token: Data, validUntilDate: Int32, requiresBiometrics: Bool) {
        self.token = token
        self.validUntilDate = validUntilDate
        self.requiresBiometrics = requiresBiometrics
    }
    
    public init(decoder: PostboxDecoder) {
        self.token = decoder.decodeBytesForKey("t")!.makeData()
        self.validUntilDate = decoder.decodeInt32ForKey("d", orElse: 0)
        self.requiresBiometrics = decoder.decodeInt32ForKey("b", orElse: 0) != 0
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeBytes(MemoryBuffer(data: self.token), forKey: "t")
        encoder.encodeInt32(self.validUntilDate, forKey: "d")
        encoder.encodeInt32(self.requiresBiometrics ? 1 : 0, forKey: "b")
    }
    
    public static func ==(lhs: TemporaryTwoStepPasswordToken, rhs: TemporaryTwoStepPasswordToken) -> Bool {
        return lhs.token == rhs.token && lhs.validUntilDate == rhs.validUntilDate && lhs.requiresBiometrics == rhs.requiresBiometrics
    }
}

public func cachedTwoStepPasswordToken(postbox: Postbox) -> Signal<TemporaryTwoStepPasswordToken?, NoError> {
    return postbox.modify { modifier -> TemporaryTwoStepPasswordToken? in
        let key = ValueBoxKey(length: 1)
        key.setUInt8(0, value: 0)
        return modifier.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedTwoStepToken, key: key)) as? TemporaryTwoStepPasswordToken
    }
}

public func cacheTwoStepPasswordToken(postbox: Postbox, token: TemporaryTwoStepPasswordToken?) -> Signal<Void, NoError> {
    return postbox.modify { modifier -> Void in
        let key = ValueBoxKey(length: 1)
        key.setUInt8(0, value: 0)
        if let token = token {
            modifier.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedTwoStepToken, key: key), entry: token, collectionSpec: ItemCacheCollectionSpec(lowWaterItemCount: 1, highWaterItemCount: 1))
        } else {
            modifier.removeItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedTwoStepToken, key: key))
        }
    }
}

public func requestTemporaryTwoStepPasswordToken(account: Account, password: String, period: Int32, requiresBiometrics: Bool) -> Signal<TemporaryTwoStepPasswordToken, AuthorizationPasswordVerificationError> {
    return twoStepAuthData(account.network)
        |> mapToSignal { authData -> Signal<TemporaryTwoStepPasswordToken, MTRpcError> in
            var data = Data()
            data.append(authData.currentSalt!)
            data.append(password.data(using: .utf8, allowLossyConversion: true)!)
            data.append(authData.currentSalt!)
            let currentPasswordHash = sha256Digest(data)
            
            return account.network.request(Api.functions.account.getTmpPassword(passwordHash: Buffer(data: currentPasswordHash), period: period), automaticFloodWait: false)
                |> map { result -> TemporaryTwoStepPasswordToken in
                    switch result {
                        case let .tmpPassword(tmpPassword, validUntil):
                            return TemporaryTwoStepPasswordToken(token: tmpPassword.makeData(), validUntilDate: validUntil, requiresBiometrics: requiresBiometrics)
                    }
                }
        }
        |> `catch` { error -> Signal<TemporaryTwoStepPasswordToken, AuthorizationPasswordVerificationError> in
            if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                return .fail(.limitExceeded)
            } else if error.errorDescription == "PASSWORD_HASH_INVALID" {
                return .fail(.invalidPassword)
            } else {
                return .fail(.generic)
            }
        }
}
