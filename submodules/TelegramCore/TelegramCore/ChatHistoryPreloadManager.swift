import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

private struct HistoryPreloadHole: Hashable, Comparable {
    let index: ChatListIndex
    let hasUnread: Bool
    let isMuted: Bool
    let hole: MessageOfInterestHole
    
    static func ==(lhs: HistoryPreloadHole, rhs: HistoryPreloadHole) -> Bool {
        return lhs.index == rhs.index && lhs.hasUnread == rhs.hasUnread && lhs.isMuted == rhs.isMuted && lhs.hole == rhs.hole
    }
    
    static func <(lhs: HistoryPreloadHole, rhs: HistoryPreloadHole) -> Bool {
        if lhs.isMuted != rhs.isMuted {
            if lhs.isMuted {
                return false
            } else {
                return true
            }
        }
        if lhs.hasUnread != rhs.hasUnread {
            if lhs.hasUnread {
                return true
            } else {
                return false
            }
        }
        return lhs.index > rhs.index
    }
    
    var hashValue: Int {
        return self.index.hashValue &* 31 &+ self.hole.hashValue
    }
}

private final class HistoryPreloadEntry: Comparable {
    var hole: HistoryPreloadHole
    private var isStarted = false
    private let disposable = MetaDisposable()
    
    init(hole: HistoryPreloadHole) {
        self.hole = hole
    }
    
    static func ==(lhs: HistoryPreloadEntry, rhs: HistoryPreloadEntry) -> Bool {
        return lhs.hole == rhs.hole
    }
    
    static func <(lhs: HistoryPreloadEntry, rhs: HistoryPreloadEntry) -> Bool {
        return lhs.hole < rhs.hole
    }
    
    func startIfNeeded(postbox: Postbox, download: Signal<Download, NoError>, queue: Queue) {
        if !self.isStarted {
            self.isStarted = true
            
            let signal: Signal<Void, NoError> = .complete() |> delay(0.3, queue: queue) |> then(download |> take(1) |> deliverOn(queue) |> mapToSignal { download -> Signal<Void, NoError> in
                return fetchMessageHistoryHole(source: .download(download), postbox: postbox, hole: self.hole.hole.hole, direction: self.hole.hole.direction, tagMask: nil, limit: 60)
            })
            self.disposable.set(signal.start())
        }
    }
    
    deinit {
        self.disposable.dispose()
    }
}

private final class HistoryPreloadViewContext {
    var index: ChatListIndex
    var hasUnread: Bool
    var isMuted: Bool
    let disposable = MetaDisposable()
    var hole: MessageOfInterestHole?
    
    var currentHole: HistoryPreloadHole? {
        if let hole = self.hole {
            return HistoryPreloadHole(index: self.index, hasUnread: self.hasUnread, isMuted: self.isMuted, hole: hole)
        } else {
            return nil
        }
    }
    
    init(index: ChatListIndex, hasUnread: Bool, isMuted: Bool) {
        self.index = index
        self.hasUnread = hasUnread
        self.isMuted = isMuted
    }
    
    deinit {
        disposable.dispose()
    }
}

final class ChatHistoryPreloadManager {
    private let queue = Queue()
    
    private let postbox: Postbox
    private let network: Network
    private let download = Promise<Download>()
    
    private var canPreloadHistoryDisposable: Disposable?
    private var canPreloadHistoryValue = false
    
    private var automaticChatListDisposable: Disposable?
    
    private var views: [PeerId: HistoryPreloadViewContext] = [:]
    
    private var entries: [HistoryPreloadEntry] = []
    
    init(postbox: Postbox, network: Network, networkState: Signal<AccountNetworkState, NoError>) {
        self.postbox = postbox
        self.network = network
        self.download.set(network.download(datacenterId: network.datacenterId, tag: nil))
        
        self.automaticChatListDisposable = (postbox.tailChatListView(count: 20, summaryComponents: ChatListEntrySummaryComponents()) |> deliverOnMainQueue).start(next: { [weak self] view in
            if let strongSelf = self {
                var indices: [(ChatListIndex, Bool, Bool)] = []
                for entry in view.0.entries {
                    if case let .MessageEntry(index, _, readState, notificationSettings, _, _, _) = entry {
                        var hasUnread = false
                        if let readState = readState {
                            hasUnread = readState.count != 0
                        }
                        var isMuted = false
                        if let notificationSettings = notificationSettings as? TelegramPeerNotificationSettings {
                            if case .muted = notificationSettings.muteState {
                                isMuted = true
                            }
                        }
                        indices.append((index, hasUnread, isMuted))
                    }
                }
                
                strongSelf.update(indices: indices)
            }
        })
        
        self.canPreloadHistoryDisposable = (networkState |> map { state -> Bool in
            switch state {
                case .online:
                    return true
                default:
                    return false
                }
            } |> distinctUntilChanged |> deliverOn(self.queue)).start(next: { [weak self] value in
                if let strongSelf = self, strongSelf.canPreloadHistoryValue != value {
                    strongSelf.canPreloadHistoryValue = value
                    if value {
                        for i in 0 ..< min(3, strongSelf.entries.count) {
                            strongSelf.entries[i].startIfNeeded(postbox: strongSelf.postbox, download: strongSelf.download.get() |> take(1), queue: strongSelf.queue)
                        }
                    }
                }
            })
    }
    
    deinit {
        self.canPreloadHistoryDisposable?.dispose()
    }
    
    func update(indices: [(ChatListIndex, Bool, Bool)]) {
        self.queue.async {
            let validPeerIds = Set(indices.map { $0.0.messageIndex.id.peerId })
            var removedPeerIds: [PeerId] = []
            for (peerId, view) in self.views {
                if !validPeerIds.contains(peerId) {
                    removedPeerIds.append(peerId)
                    if let hole = view.currentHole {
                        self.update(from: hole, to: nil)
                    }
                }
            }
            for peerId in removedPeerIds {
                self.views.removeValue(forKey: peerId)
            }
            for (index, hasUnread, isMuted) in indices {
                if let view = self.views[index.messageIndex.id.peerId] {
                    if view.index != index || view.hasUnread != hasUnread || view.isMuted != isMuted {
                        let previousHole = view.currentHole
                        view.index = index
                        view.hasUnread = hasUnread
                        view.isMuted = isMuted
                        
                        let updatedHole = view.currentHole
                        if previousHole != updatedHole {
                            self.update(from: previousHole, to: updatedHole)
                        }
                    }
                } else {
                    let view = HistoryPreloadViewContext(index: index, hasUnread: hasUnread, isMuted: isMuted)
                    self.views[index.messageIndex.id.peerId] = view
                    let key: PostboxViewKey = .messageOfInterestHole(peerId: index.messageIndex.id.peerId, namespace: index.messageIndex.id.namespace, count: 60)
                    view.disposable.set((self.postbox.combinedView(keys: [key]) |> deliverOn(self.queue)).start(next: { [weak self] next in
                        if let strongSelf = self, let value = next.views[key] as? MessageOfInterestHolesView {
                            if let view = strongSelf.views[index.messageIndex.id.peerId] {
                                let previousHole = view.currentHole
                                view.hole = value.closestHole
                                let updatedHole = view.currentHole
                                if previousHole != updatedHole {
                                    strongSelf.update(from: previousHole, to: updatedHole)
                                }
                            }
                        }
                    }))
                }
            }
        }
    }
    
    private func update(from previousHole: HistoryPreloadHole?, to updatedHole: HistoryPreloadHole?) {
        assert(self.queue.isCurrent())
        if previousHole == updatedHole {
            return
        }
        
        var skipUpdated = false
        if let previousHole = previousHole {
            for i in (0 ..< self.entries.count).reversed() {
                if self.entries[i].hole == previousHole {
                    if let updatedHole = updatedHole, updatedHole.hole == self.entries[i].hole.hole {
                        self.entries[i].hole = updatedHole
                        skipUpdated = true
                    } else {
                        self.entries.remove(at: i)
                    }
                    break
                }
            }
        }
        
        if let updatedHole = updatedHole, !skipUpdated {
            var found = false
            for i in 0 ..< self.entries.count {
                if self.entries[i].hole == updatedHole {
                    found = true
                    break
                }
            }
            if !found {
                self.entries.append(HistoryPreloadEntry(hole: updatedHole))
                self.entries.sort()
            }
        }
        
        if self.canPreloadHistoryValue {
            for i in 0 ..< min(3, self.entries.count) {
                self.entries[i].startIfNeeded(postbox: self.postbox, download: self.download.get() |> take(1), queue: self.queue)
            }
        }
    }
}
