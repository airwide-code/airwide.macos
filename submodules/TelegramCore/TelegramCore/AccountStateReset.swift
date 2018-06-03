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

func accountStateReset(postbox: Postbox, network: Network) -> Signal<Void, NoError> {
    let pinnedChats: Signal<Api.messages.PeerDialogs, NoError> = network.request(Api.functions.messages.getPinnedDialogs())
        |> retryRequest
    let state: Signal<Api.updates.State, NoError> =
        network.request(Api.functions.updates.getState())
            |> retryRequest
    
    return combineLatest(network.request(Api.functions.messages.getDialogs(flags: 0, offsetDate: 0, offsetId: 0, offsetPeer: .inputPeerEmpty, limit: 100))
        |> retryRequest, pinnedChats, state)
        |> mapToSignal { result, pinnedChats, state -> Signal<Void, NoError> in
            var dialogsDialogs: [Api.Dialog] = []
            var dialogsMessages: [Api.Message] = []
            var dialogsChats: [Api.Chat] = []
            var dialogsUsers: [Api.User] = []
            
            var holeExists = false
            
            switch result {
                case let .dialogs(dialogs, messages, chats, users):
                    dialogsDialogs = dialogs
                    dialogsMessages = messages
                    dialogsChats = chats
                    dialogsUsers = users
                case let .dialogsSlice(_, dialogs, messages, chats, users):
                    dialogsDialogs = dialogs
                    dialogsMessages = messages
                    dialogsChats = chats
                    dialogsUsers = users
                    holeExists = true
            }
            
            let replacePinnedPeerIds: [PeerId]
            switch pinnedChats {
                case let .peerDialogs(apiDialogs, apiMessages, apiChats, apiUsers, _):
                    dialogsDialogs.append(contentsOf: apiDialogs)
                    dialogsMessages.append(contentsOf: apiMessages)
                    dialogsChats.append(contentsOf: apiChats)
                    dialogsUsers.append(contentsOf: apiUsers)
                    
                    var peerIds: [PeerId] = []
                    
                    for dialog in apiDialogs {
                        let apiPeer: Api.Peer
                        switch dialog {
                            case let .dialog(_, peer, _, _, _, _, _, _, _, _):
                                apiPeer = peer
                        }
                        
                        let peerId = apiPeer.peerId
                        
                        peerIds.append(peerId)
                }
                
                replacePinnedPeerIds = peerIds
            }
            
            var replacementHole: ChatListHole?
            var storeMessages: [StoreMessage] = []
            var readStates: [PeerId: [MessageId.Namespace: PeerReadState]] = [:]
            var mentionTagSummaries: [PeerId: MessageHistoryTagNamespaceSummary] = [:]
            var chatStates: [PeerId: PeerChatState] = [:]
            var notificationSettings: [PeerId: PeerNotificationSettings] = [:]
            
            var topMesageIds: [PeerId: MessageId] = [:]
            
            for dialog in dialogsDialogs {
                let apiPeer: Api.Peer
                let apiReadInboxMaxId: Int32
                let apiReadOutboxMaxId: Int32
                let apiTopMessage: Int32
                let apiUnreadCount: Int32
                let apiUnreadMentionsCount: Int32
                var apiChannelPts: Int32?
                let apiNotificationSettings: Api.PeerNotifySettings
                switch dialog {
                    case let .dialog(_, peer, topMessage, readInboxMaxId, readOutboxMaxId, unreadCount, unreadMentionsCount, peerNotificationSettings, pts, _):
                        apiPeer = peer
                        apiTopMessage = topMessage
                        apiReadInboxMaxId = readInboxMaxId
                        apiReadOutboxMaxId = readOutboxMaxId
                        apiUnreadCount = unreadCount
                        apiUnreadMentionsCount = unreadMentionsCount
                        apiNotificationSettings = peerNotificationSettings
                        apiChannelPts = pts
                }
                
                let peerId: PeerId
                switch apiPeer {
                    case let .peerUser(userId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                    case let .peerChat(chatId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                    case let .peerChannel(channelId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                }
                
                if readStates[peerId] == nil {
                    readStates[peerId] = [:]
                }
                readStates[peerId]![Namespaces.Message.Cloud] = .idBased(maxIncomingReadId: apiReadInboxMaxId, maxOutgoingReadId: apiReadOutboxMaxId, maxKnownId: apiTopMessage, count: apiUnreadCount)
                
                if apiTopMessage != 0 {
                    mentionTagSummaries[peerId] = MessageHistoryTagNamespaceSummary(version: 1, count: apiUnreadMentionsCount, range: MessageHistoryTagNamespaceCountValidityRange(maxId: apiTopMessage))
                    topMesageIds[peerId] = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: apiTopMessage)
                }
                
                if let apiChannelPts = apiChannelPts {
                    chatStates[peerId] = ChannelState(pts: apiChannelPts, invalidatedPts: apiChannelPts)
                } else {
                    switch state {
                        case let .state(pts, _, _, _, _):
                            chatStates[peerId] = RegularChatState(invalidatedPts: pts)
                    }
                }
                
                notificationSettings[peerId] = TelegramPeerNotificationSettings(apiSettings: apiNotificationSettings)
            }
            
            for message in dialogsMessages {
                if let storeMessage = StoreMessage(apiMessage: message) {
                    storeMessages.append(storeMessage)
                }
            }
            
            if holeExists {
                for dialog in dialogsDialogs {
                    switch dialog {
                        case let .dialog(flags, peer, topMessage, _, _, _, _, _, _, _):
                            let isPinned = (flags & (1 << 2)) != 0
                            
                            if !isPinned {
                                var timestamp: Int32?
                                for message in storeMessages {
                                    if case let .Id(id) = message.id, id.id == topMessage {
                                        timestamp = message.timestamp
                                    }
                                }
                                
                                if let timestamp = timestamp {
                                    let index = MessageIndex(id: MessageId(peerId: peer.peerId, namespace: Namespaces.Message.Cloud, id: topMessage - 1), timestamp: timestamp)
                                    if (replacementHole == nil || replacementHole!.index > index) {
                                        replacementHole = ChatListHole(index: index)
                                    }
                                }
                            }
                    }
                }
            }
            
            var peers: [Peer] = []
            var peerPresences: [PeerId: PeerPresence] = [:]
            for chat in dialogsChats {
                if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                    peers.append(groupOrChannel)
                }
            }
            for user in dialogsUsers {
                let telegramUser = TelegramUser(user: user)
                peers.append(telegramUser)
                if let presence = TelegramUserPresence(apiUser: user) {
                    peerPresences[telegramUser.id] = presence
                }
            }
            
            return postbox.modify { modifier -> Void in
                modifier.resetChatList(keepPeerNamespaces: Set([Namespaces.Peer.SecretChat]), replacementHole: replacementHole)
                
                updatePeers(modifier: modifier, peers: peers, update: { _, updated -> Peer in
                    return updated
                })
                modifier.updatePeerPresences(peerPresences)
                
                modifier.updateCurrentPeerNotificationSettings(notificationSettings)
                
                var allPeersWithMessages = Set<PeerId>()
                for message in storeMessages {
                    if !allPeersWithMessages.contains(message.id.peerId) {
                        allPeersWithMessages.insert(message.id.peerId)
                    }
                }
                
                for (_, messageId) in topMesageIds {
                    if messageId.id > 1 {
                        var skipHole = false
                        if let localTopId = modifier.getTopMesssageIndex(peerId: messageId.peerId, namespace: messageId.namespace)?.id {
                            if localTopId >= messageId {
                                skipHole = true
                            }
                        }
                        if !skipHole {
                            modifier.addHole(MessageId(peerId: messageId.peerId, namespace: messageId.namespace, id: messageId.id - 1))
                        }
                    }
                }
                
                let _ = modifier.addMessages(storeMessages, location: .UpperHistoryBlock)
                
                modifier.resetIncomingReadStates(readStates)
                
                for (peerId, chatState) in chatStates {
                    if let chatState = chatState as? ChannelState {
                        if let current = modifier.getPeerChatState(peerId) as? ChannelState {
                            modifier.setPeerChatState(peerId, state: current.withUpdatedPts(chatState.pts))
                        } else {
                            modifier.setPeerChatState(peerId, state: chatState)
                        }
                    } else {
                        modifier.setPeerChatState(peerId, state: chatState)
                    }
                }
                
                modifier.setPinnedPeerIds(replacePinnedPeerIds)
                
                for (peerId, summary) in mentionTagSummaries {
                    modifier.replaceMessageTagSummary(peerId: peerId, tagMask: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud, count: summary.count, maxId: summary.range.maxId)
                }
                
                if let currentState = modifier.getState() as? AuthorizedAccountState, let embeddedState = currentState.state {
                    switch state {
                        case let .state(pts, _, _, seq, _):
                            modifier.setState(currentState.changedState(AuthorizedAccountState.State(pts: pts, qts: embeddedState.qts, date: embeddedState.date, seq: seq)))
                    }
                }
            }
        }
}
