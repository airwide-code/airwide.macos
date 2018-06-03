import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

public func requestAccountPrivacySettings(account: Account) -> Signal<AccountPrivacySettings, NoError> {
    let lastSeenPrivacy = account.network.request(Api.functions.account.getPrivacy(key: .inputPrivacyKeyStatusTimestamp))
    let groupPrivacy = account.network.request(Api.functions.account.getPrivacy(key: .inputPrivacyKeyChatInvite))
    let voiceCallPrivacy = account.network.request(Api.functions.account.getPrivacy(key: .inputPrivacyKeyPhoneCall))
    let autoremoveTimeout = account.network.request(Api.functions.account.getAccountTTL())
    return combineLatest(lastSeenPrivacy, groupPrivacy, voiceCallPrivacy, autoremoveTimeout)
        |> retryRequest
        |> mapToSignal { lastSeenPrivacy, groupPrivacy, voiceCallPrivacy, autoremoveTimeout -> Signal<AccountPrivacySettings, NoError> in
            let accountTimeoutSeconds: Int32
            switch autoremoveTimeout {
                case let .accountDaysTTL(days):
                    accountTimeoutSeconds = days * 24 * 60 * 60
            }
            
            
            let lastSeenRules: [Api.PrivacyRule]
            let groupRules: [Api.PrivacyRule]
            let voiceRules: [Api.PrivacyRule]
            var apiUsers: [Api.User] = []
            
            switch lastSeenPrivacy {
                case let .privacyRules(rules, users):
                    apiUsers.append(contentsOf: users)
                    lastSeenRules = rules
            }
            
            switch groupPrivacy {
                case let .privacyRules(rules, users):
                    apiUsers.append(contentsOf: users)
                    groupRules = rules
            }
            
            switch voiceCallPrivacy {
                case let .privacyRules(rules, users):
                    apiUsers.append(contentsOf: users)
                    voiceRules = rules
            }
            
            let peers = apiUsers.map { TelegramUser(user: $0) }
            
            return account.postbox.modify { modifier -> AccountPrivacySettings in
                updatePeers(modifier: modifier, peers: peers, update: { _, updated in
                    return updated
                })
                
                return AccountPrivacySettings(presence: SelectivePrivacySettings(apiRules: lastSeenRules), groupInvitations: SelectivePrivacySettings(apiRules: groupRules), voiceCalls: SelectivePrivacySettings(apiRules: voiceRules), accountRemovalTimeout: accountTimeoutSeconds)
            }
        }
}

public func updateAccountRemovalTimeout(account: Account, timeout: Int32) -> Signal<Void, NoError> {
    return account.network.request(Api.functions.account.setAccountTTL(ttl: .accountDaysTTL(days: timeout / (24 * 60 * 60))))
        |> retryRequest
        |> mapToSignal { _ -> Signal<Void, NoError> in
            return .complete()
        }
}

public enum UpdateSelectiveAccountPrivacySettingsType {
    case presence
    case groupInvitations
    case voiceCalls
    
    var apiKey: Api.InputPrivacyKey {
        switch self {
            case .presence:
                return .inputPrivacyKeyStatusTimestamp
            case .groupInvitations:
                return .inputPrivacyKeyChatInvite
            case .voiceCalls:
                return .inputPrivacyKeyPhoneCall
        }
    }
}

private func apiInputUsers(modifier: Modifier, peerIds: [PeerId]) -> [Api.InputUser] {
    var result: [Api.InputUser] = []
    for peerId in peerIds {
        if let peer = modifier.getPeer(peerId), let inputUser = apiInputUser(peer) {
            result.append(inputUser)
        }
    }
    return result
}

public func updateSelectiveAccountPrivacySettings(account: Account, type: UpdateSelectiveAccountPrivacySettingsType, settings: SelectivePrivacySettings) -> Signal<Void, NoError> {
    return account.postbox.modify { modifier -> Signal<Void, NoError> in
        var rules: [Api.InputPrivacyRule] = []
        switch settings {
            case let .disableEveryone(enableFor):
                if !enableFor.isEmpty {
                    rules.append(Api.InputPrivacyRule.inputPrivacyValueAllowUsers(users: apiInputUsers(modifier: modifier, peerIds: Array(enableFor))))
                }
                rules.append(Api.InputPrivacyRule.inputPrivacyValueDisallowAll)
            case let .enableContacts(enableFor, disableFor):
                if !enableFor.isEmpty {
                    rules.append(Api.InputPrivacyRule.inputPrivacyValueAllowUsers(users: apiInputUsers(modifier: modifier, peerIds: Array(enableFor))))
                }
                if !disableFor.isEmpty {
                    rules.append(Api.InputPrivacyRule.inputPrivacyValueDisallowUsers(users: apiInputUsers(modifier: modifier, peerIds: Array(disableFor))))
                }
                rules.append(Api.InputPrivacyRule.inputPrivacyValueAllowContacts)
            case let.enableEveryone(disableFor):
                if !disableFor.isEmpty {
                    rules.append(Api.InputPrivacyRule.inputPrivacyValueDisallowUsers(users: apiInputUsers(modifier: modifier, peerIds: Array(disableFor))))
                }
                rules.append(Api.InputPrivacyRule.inputPrivacyValueAllowAll)
        }
        return account.network.request(Api.functions.account.setPrivacy(key: type.apiKey, rules: rules))
            |> retryRequest
            |> mapToSignal { _ -> Signal<Void, NoError> in
                return .complete()
        }
    } |> switchToLatest
}
