/// Channels waiting for their guide listings to load from the on-disk guide, newest first
/// (Build 61).
///
/// Every guide row asks for its channel's listings when it is built, so a fast fling through a
/// 25,000-channel list asks for hundreds of channels the viewer only passes. Until Build 61 the
/// queue was a dictionary: it loaded batches in hash order, and once 512 requests were waiting it
/// ignored new ones. The rows still on screen when a fling stopped were the newest requests, so
/// they could wait behind hundreds of passed rows or not be queued at all and read "No guide
/// information" although the guide had listings for them.
///
/// Now the newest requests load first and, when the queue is full, the oldest request makes room.
struct LiveTVGuideResidencyQueue {
    /// The same bound as before: at most this many channels wait at once.
    static let capacity = 512

    private var channelIDs: [String: Set<String>] = [:]
    /// Guide keys, oldest request first.
    private var order: [String] = []

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }

    func contains(_ key: String) -> Bool { channelIDs[key] != nil }

    /// Queues `key` for `channelID`, or moves it to the front if it is already waiting. Returns the
    /// request that made room, if the queue was full.
    @discardableResult
    mutating func request(_ key: String, channelID: String) -> (key: String, channelIDs: Set<String>)? {
        if channelIDs[key] != nil {
            channelIDs[key]?.insert(channelID)
            if order.last != key, let index = order.lastIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
            return nil
        }
        var evicted: (key: String, channelIDs: Set<String>)?
        if order.count >= Self.capacity {
            let oldest = order.removeFirst()
            evicted = (oldest, channelIDs.removeValue(forKey: oldest) ?? [])
        }
        channelIDs[key] = [channelID]
        order.append(key)
        return evicted
    }

    /// Removes and returns up to `limit` requests, newest first.
    mutating func takeNewest(_ limit: Int) -> [(key: String, channelIDs: Set<String>)] {
        let taken = order.suffix(max(0, limit)).reversed()
        order.removeLast(taken.count)
        return taken.map { ($0, channelIDs.removeValue(forKey: $0) ?? []) }
    }

    mutating func removeAll() {
        channelIDs.removeAll()
        order.removeAll()
    }
}
