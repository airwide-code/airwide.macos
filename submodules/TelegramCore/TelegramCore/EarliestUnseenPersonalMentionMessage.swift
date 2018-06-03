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

public enum EarliestUnseenPersonalMentionMessageResult {
    case loading
    case result(MessageId?)
}

public func earliestUnseenPersonalMentionMessage(postbox: Postbox, network: Network, peerId: PeerId) -> Signal<EarliestUnseenPersonalMentionMessageResult, NoError> {
    return earliestUnseenPersonalMentionMessage(postbox: postbox, network: network, peerId: peerId, locally: false)
}

private func earliestUnseenPersonalMentionMessage(postbox: Postbox, network: Network, peerId: PeerId, locally: Bool) -> Signal<EarliestUnseenPersonalMentionMessageResult, NoError> {
    return postbox.modify { modifier -> Signal<EarliestUnseenPersonalMentionMessageResult, NoError> in
        var resultMessage: Message?
        var resultHole: MessageHistoryHole?
        modifier.scanMessages(peerId: peerId, tagMask: .unseenPersonalMessage, { entry in
            switch entry {
                case let .message(message):
                    for attribute in message.attributes {
                        if let attribute = attribute as? ConsumablePersonalMentionMessageAttribute, !attribute.pending {
                            resultMessage = message
                            return false
                        }
                    }
                case let .hole(hole):
                    resultHole = hole
                    return false
            }
            return true
        })
        
        if let resultMessage = resultMessage {
            var invalidateHistoryPts: Int32?
            
            if peerId.namespace == Namespaces.Peer.CloudChannel {
                if let channelState = modifier.getPeerChatState(peerId) as? ChannelState {
                    if let invalidatedPts = channelState.invalidatedPts {
                        var messagePts: Int32?
                        for attribute in resultMessage.attributes {
                            if let attribute = attribute as? ChannelMessageStateVersionAttribute {
                                messagePts = attribute.pts
                                break
                            }
                        }
                        
                        if let messagePts = messagePts {
                            if messagePts < invalidatedPts {
                                invalidateHistoryPts = invalidatedPts
                            }
                        } else {
                            invalidateHistoryPts = invalidatedPts
                        }
                    }
                }
            }
            
            if !locally, let _ = invalidateHistoryPts {
                let validateSignal = fetchMessageHistoryHole(source: .network(network), postbox: postbox, hole: MessageHistoryHole(stableId: UInt32.max, maxIndex: MessageIndex.upperBound(peerId: peerId), min: resultMessage.id.id - 1, tags: 0), direction: .LowerToUpper, tagMask: .unseenPersonalMessage)
                    |> mapToSignal { _ -> Signal<EarliestUnseenPersonalMentionMessageResult, NoError> in
                        return .complete()
                    }
                    |> then(earliestUnseenPersonalMentionMessage(postbox: postbox, network: network, peerId: peerId, locally: true))
                return .single(.loading) |> then(validateSignal)
            } else {
                return .single(.result(resultMessage.id))
            }
        } else if let resultHole = resultHole, !locally {
            let validateSignal = fetchMessageHistoryHole(source: .network(network), postbox: postbox, hole: resultHole, direction: .LowerToUpper, tagMask: .unseenPersonalMessage)
                |> mapToSignal { _ -> Signal<EarliestUnseenPersonalMentionMessageResult, NoError> in
                    return .complete()
                }
                |> then(earliestUnseenPersonalMentionMessage(postbox: postbox, network: network, peerId: peerId, locally: true))
            return .single(.loading) |> then(validateSignal)
        } else if let summary = modifier.getMessageTagSummary(peerId: peerId, tagMask: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud), summary.count > 0 {
            modifier.replaceMessageTagSummary(peerId: peerId, tagMask: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud, count: 0, maxId: summary.range.maxId)
        }
        
        return .single(.result(nil))
    } |> switchToLatest
}
