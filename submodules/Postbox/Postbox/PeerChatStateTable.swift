import Foundation

final class PeerChatStateTable: Table {
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .int64)
    }
    
    private var cachedPeerChatStates: [PeerId: PostboxCoding?] = [:]
    private var updatedPeerIds = Set<PeerId>()
    
    private let sharedKey = ValueBoxKey(length: 8)
    
    private func key(_ id: PeerId) -> ValueBoxKey {
        self.sharedKey.setInt64(0, value: id.toInt64())
        return self.sharedKey
    }
    
    func get(_ id: PeerId) -> PostboxCoding? {
        if let state = self.cachedPeerChatStates[id] {
            return state
        } else {
            if let value = self.valueBox.get(self.table, key: self.key(id)), let state = PostboxDecoder(buffer: value).decodeRootObject() {
                self.cachedPeerChatStates[id] = state
                return state
            } else {
                self.cachedPeerChatStates[id] = nil
                return nil
            }
        }
    }
    
    func set(_ id: PeerId, state: PostboxCoding?) {
        self.cachedPeerChatStates[id] = state
        self.updatedPeerIds.insert(id)
    }
    
    override func clearMemoryCache() {
        self.cachedPeerChatStates.removeAll()
        self.updatedPeerIds.removeAll()
    }
    
    override func beforeCommit() {
        if !self.updatedPeerIds.isEmpty {
            let sharedEncoder = PostboxEncoder()
            for id in self.updatedPeerIds {
                if let wrappedState = self.cachedPeerChatStates[id], let state = wrappedState {
                    sharedEncoder.reset()
                    sharedEncoder.encodeRootObject(state)
                    self.valueBox.set(self.table, key: self.key(id), value: sharedEncoder.readBufferNoCopy())
                } else {
                    self.valueBox.remove(self.table, key: self.key(id))
                }
            }
            self.updatedPeerIds.removeAll()
        }
    }
}
