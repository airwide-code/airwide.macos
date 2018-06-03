import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

func fetchAndUpdateSupplementalCachedPeerData(peerId: PeerId, network: Network, postbox: Postbox) -> Signal<Void, NoError> {
    return postbox.modify { modifier -> Signal<Void, NoError> in
        if let peer = modifier.getPeer(peerId) {
            let cachedData = modifier.getPeerCachedData(peerId: peerId)
            
            if let cachedData = cachedData as? CachedUserData {
                if cachedData.reportStatus != .unknown {
                    return .complete()
                }
            } else if let cachedData = cachedData as? CachedGroupData {
                if cachedData.reportStatus != .unknown {
                    return .complete()
                }
            } else if let cachedData = cachedData as? CachedChannelData {
                if cachedData.reportStatus != .unknown {
                    return .complete()
                }
            } else if let cachedData = cachedData as? CachedSecretChatData {
                if cachedData.reportStatus != .unknown {
                    return .complete()
                }
            }
            
            if peerId.namespace == Namespaces.Peer.SecretChat {
                return postbox.modify { modifier -> Void in
                    let reportStatus: PeerReportStatus
                    if let peer = modifier.getPeer(peerId), let associatedPeerId = peer.associatedPeerId, !modifier.isPeerContact(peerId: associatedPeerId) {
                        if let peer = peer as? TelegramSecretChat, case .creator = peer.role {
                            reportStatus = .none
                        } else {
                            reportStatus = .canReport
                        }
                    } else {
                        reportStatus = .none
                    }
                    
                    modifier.updatePeerCachedData(peerIds: [peerId], update: { peerId, current in
                        if let current = current as? CachedSecretChatData {
                            return current.withUpdatedReportStatus(reportStatus)
                        } else {
                            return CachedSecretChatData(reportStatus: reportStatus)
                        }
                    })
                }
            } else if let inputPeer = apiInputPeer(peer) {
                return network.request(Api.functions.messages.getPeerSettings(peer: inputPeer))
                    |> retryRequest
                    |> mapToSignal { peerSettings -> Signal<Void, NoError> in
                        let reportStatus: PeerReportStatus
                        switch peerSettings {
                            case let .peerSettings(flags):
                                reportStatus = (flags & (1 << 0) != 0) ? .canReport : .none
                        }
                        
                        return postbox.modify { modifier -> Void in
                            modifier.updatePeerCachedData(peerIds: Set([peerId]), update: { _, current in
                                switch peerId.namespace {
                                    case Namespaces.Peer.CloudUser:
                                        let previous: CachedUserData
                                        if let current = current as? CachedUserData {
                                            previous = current
                                        } else {
                                            previous = CachedUserData()
                                        }
                                        return previous.withUpdatedReportStatus(reportStatus)
                                    case Namespaces.Peer.CloudGroup:
                                        let previous: CachedGroupData
                                        if let current = current as? CachedGroupData {
                                            previous = current
                                        } else {
                                            previous = CachedGroupData()
                                        }
                                        return previous.withUpdatedReportStatus(reportStatus)
                                    case Namespaces.Peer.CloudChannel:
                                        let previous: CachedChannelData
                                        if let current = current as? CachedChannelData {
                                            previous = current
                                        } else {
                                            previous = CachedChannelData()
                                        }
                                        return previous.withUpdatedReportStatus(reportStatus)
                                    default:
                                        break
                                }
                                return current
                            })
                        }
                    }
            } else {
                return .complete()
            }
        } else {
            return .complete()
        }
    } |> switchToLatest
}

func fetchAndUpdateCachedPeerData(peerId: PeerId, network: Network, postbox: Postbox) -> Signal<Void, NoError> {
    return postbox.loadedPeerWithId(peerId)
        |> mapToSignal { peer -> Signal<Void, NoError> in
            if let inputUser = apiInputUser(peer) {
                return network.request(Api.functions.users.getFullUser(id: inputUser))
                    |> retryRequest
                    |> mapToSignal { result -> Signal<Void, NoError> in
                        return postbox.modify { modifier -> Void in
                            switch result {
                                case let .userFull(_, user, _, _, _, notifySettings, _, _):
                                    let telegramUser = TelegramUser(user: user)
                                    updatePeers(modifier: modifier, peers: [telegramUser], update: { _, updated -> Peer in
                                        return updated
                                    })
                                    modifier.updateCurrentPeerNotificationSettings([peerId: TelegramPeerNotificationSettings(apiSettings: notifySettings)])
                                    if let presence = TelegramUserPresence(apiUser: user) {
                                        modifier.updatePeerPresences([peer.id: presence])
                                    }
                            }
                            modifier.updatePeerCachedData(peerIds: [peerId], update: { peerId, current in
                                let previous: CachedUserData
                                if let current = current as? CachedUserData {
                                    previous = current
                                } else {
                                    previous = CachedUserData()
                                }
                                switch result {
                                    case let .userFull(flags, _, about, _, _, _, apiBotInfo, commonChatsCount):
                                        let botInfo: BotInfo?
                                        if let apiBotInfo = apiBotInfo {
                                            botInfo = BotInfo(apiBotInfo: apiBotInfo)
                                        } else {
                                            botInfo = nil
                                        }
                                        let isBlocked = (flags & (1 << 0)) != 0
                                        return previous.withUpdatedAbout(about).withUpdatedBotInfo(botInfo).withUpdatedCommonGroupCount(commonChatsCount).withUpdatedIsBlocked(isBlocked)
                                }
                            })
                        }
                    }
            } else if let _ = peer as? TelegramGroup {
                return network.request(Api.functions.messages.getFullChat(chatId: peerId.id))
                    |> retryRequest
                    |> mapToSignal { result -> Signal<Void, NoError> in
                        return postbox.modify { modifier -> Void in
                            switch result {
                                case let .chatFull(fullChat, chats, users):
                                    switch fullChat {
                                        case let .chatFull(_, _, _, notifySettings, _, _):
                                            modifier.updateCurrentPeerNotificationSettings([peerId: TelegramPeerNotificationSettings(apiSettings: notifySettings)])
                                        case .channelFull:
                                            break
                                    }
                                    
                                    switch fullChat {
                                        case let .chatFull(_, apiParticipants, _, _, apiExportedInvite, apiBotInfos):
                                            var botInfos: [CachedPeerBotInfo] = []
                                            for botInfo in apiBotInfos {
                                                switch botInfo {
                                                case let .botInfo(userId, _, _):
                                                    let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                                                    let parsedBotInfo = BotInfo(apiBotInfo: botInfo)
                                                    botInfos.append(CachedPeerBotInfo(peerId: peerId, botInfo: parsedBotInfo))
                                                }
                                            }
                                            let participants = CachedGroupParticipants(apiParticipants: apiParticipants)
                                            let exportedInvitation = ExportedInvitation(apiExportedInvite: apiExportedInvite)
                                        
                                            var peers: [Peer] = []
                                            var peerPresences: [PeerId: PeerPresence] = [:]
                                            for chat in chats {
                                                if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                                    peers.append(groupOrChannel)
                                                }
                                            }
                                            for user in users {
                                                let telegramUser = TelegramUser(user: user)
                                                peers.append(telegramUser)
                                                if let presence = TelegramUserPresence(apiUser: user) {
                                                    peerPresences[telegramUser.id] = presence
                                                }
                                            }
                                            
                                            updatePeers(modifier: modifier, peers: peers, update: { _, updated -> Peer in
                                                return updated
                                            })
                                            
                                            modifier.updatePeerPresences(peerPresences)
                                            
                                            modifier.updatePeerCachedData(peerIds: [peerId], update: { _, current in
                                                let previous: CachedGroupData
                                                if let current = current as? CachedGroupData {
                                                    previous = current
                                                } else {
                                                    previous = CachedGroupData()
                                                }
                                                
                                                return previous.withUpdatedParticipants(participants).withUpdatedExportedInvitation(exportedInvitation).withUpdatedBotInfos(botInfos)
                                            })
                                        case .channelFull:
                                            break
                                    }
                            }
                        }
                    }
            } else if let inputChannel = apiInputChannel(peer) {
                return network.request(Api.functions.channels.getFullChannel(channel: inputChannel))
                    |> retryRequest
                    |> mapToSignal { result -> Signal<Void, NoError> in
                        return postbox.modify { modifier -> Void in
                            switch result {
                                case let .chatFull(fullChat, chats, users):
                                    switch fullChat {
                                        case let .channelFull(_, _, _, _, _, _, _, _, _, _, _, notifySettings, _, _, _, _, _, _, _):
                                            modifier.updateCurrentPeerNotificationSettings([peerId: TelegramPeerNotificationSettings(apiSettings: notifySettings)])
                                        case .chatFull:
                                            break
                                    }
                                    
                                    switch fullChat {
                                        case let .channelFull(flags, _, about, participantsCount, adminsCount, kickedCount, bannedCount, _, _, _, _, _, apiExportedInvite, apiBotInfos, migratedFromChatId, migratedFromMaxId, pinnedMsgId, stickerSet, minAvailableMsgId):
                                            var channelFlags = CachedChannelFlags()
                                            if (flags & (1 << 3)) != 0 {
                                                channelFlags.insert(.canDisplayParticipants)
                                            }
                                            if (flags & (1 << 6)) != 0 {
                                                channelFlags.insert(.canChangeUsername)
                                            }
                                            if (flags & (1 << 10)) == 0 {
                                                channelFlags.insert(.preHistoryEnabled)
                                            }
                                            if (flags & (1 << 7)) != 0 {
                                                channelFlags.insert(.canSetStickerSet)
                                            }
                                            var botInfos: [CachedPeerBotInfo] = []
                                            for botInfo in apiBotInfos {
                                                switch botInfo {
                                                case let .botInfo(userId, _, _):
                                                    let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                                                    let parsedBotInfo = BotInfo(apiBotInfo: botInfo)
                                                    botInfos.append(CachedPeerBotInfo(peerId: peerId, botInfo: parsedBotInfo))
                                                }
                                            }
                                            
                                            var pinnedMessageId: MessageId?
                                            if let pinnedMsgId = pinnedMsgId {
                                                pinnedMessageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: pinnedMsgId)
                                            }
                                            
                                            var minAvailableMessageId: MessageId?
                                            if let minAvailableMsgId = minAvailableMsgId {
                                                minAvailableMessageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: minAvailableMsgId)
                                                
                                                if let pinnedMsgId = pinnedMsgId, pinnedMsgId < minAvailableMsgId {
                                                    pinnedMessageId = nil
                                                }
                                            }
                                            
                                            var migrationReference: ChannelMigrationReference?
                                            if let migratedFromChatId = migratedFromChatId, let migratedFromMaxId = migratedFromMaxId {
                                                migrationReference = ChannelMigrationReference(maxMessageId: MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudGroup, id: migratedFromChatId), namespace: Namespaces.Message.Cloud, id: migratedFromMaxId))
                                            }
                                            
                                            var peers: [Peer] = []
                                            var peerPresences: [PeerId: PeerPresence] = [:]
                                            for chat in chats {
                                                if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                                                    peers.append(groupOrChannel)
                                                }
                                            }
                                            for user in users {
                                                let telegramUser = TelegramUser(user: user)
                                                peers.append(telegramUser)
                                                if let presence = TelegramUserPresence(apiUser: user) {
                                                    peerPresences[telegramUser.id] = presence
                                                }
                                            }
                                            
                                            updatePeers(modifier: modifier, peers: peers, update: { _, updated -> Peer in
                                                return updated
                                            })
                                            
                                            modifier.updatePeerPresences(peerPresences)
                                            
                                            let stickerPack: StickerPackCollectionInfo? = stickerSet.flatMap { apiSet -> StickerPackCollectionInfo in
                                                let namespace: ItemCollectionId.Namespace
                                                switch apiSet {
                                                    case let .stickerSet(flags, _, _, _, _, _, _):
                                                        if (flags & (1 << 3)) != 0 {
                                                            namespace = Namespaces.ItemCollection.CloudMaskPacks
                                                        } else {
                                                            namespace = Namespaces.ItemCollection.CloudStickerPacks
                                                        }
                                                }
                                                
                                                return StickerPackCollectionInfo(apiSet: apiSet, namespace: namespace)
                                            }
                                            
                                            var minAvailableMessageIdUpdated = false
                                            modifier.updatePeerCachedData(peerIds: [peerId], update: { _, current in
                                                let previous: CachedChannelData
                                                if let current = current as? CachedChannelData {
                                                    previous = current
                                                } else {
                                                    previous = CachedChannelData()
                                                }
                                                
                                                minAvailableMessageIdUpdated = previous.minAvailableMessageId != minAvailableMessageId
                                                
                                                return previous.withUpdatedFlags(channelFlags)
                                                    .withUpdatedAbout(about)
                                                    .withUpdatedParticipantsSummary(CachedChannelParticipantsSummary(memberCount: participantsCount, adminCount: adminsCount, bannedCount: bannedCount, kickedCount: kickedCount))
                                                    .withUpdatedExportedInvitation(ExportedInvitation(apiExportedInvite: apiExportedInvite))
                                                    .withUpdatedBotInfos(botInfos)
                                                    .withUpdatedPinnedMessageId(pinnedMessageId)
                                                    .withUpdatedStickerPack(stickerPack)
                                                    .withUpdatedMinAvailableMessageId(minAvailableMessageId)
                                                    .withUpdatedMigrationReference(migrationReference)
                                            })
                                        
                                            if let minAvailableMessageId = minAvailableMessageId, minAvailableMessageIdUpdated {
                                                modifier.deleteMessagesInRange(peerId: peerId, namespace: minAvailableMessageId.namespace, minId: 1, maxId: minAvailableMessageId.id)
                                            }
                                        case .chatFull:
                                            break
                                    }
                            }
                        }
                    }
            } else {
                return .complete()
            }
        }
}
