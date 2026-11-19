/// Keeps recently read or inserted translation segments within an entry limit.
final class TranslationSegmentCache<Key: Hashable> {
    private final class Entry {
        let key: Key
        var output: String
        weak var previous: Entry?
        var next: Entry?

        init(key: Key, output: String) {
            self.key = key
            self.output = output
        }
    }

    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var oldest: Entry?
    private var newest: Entry?

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func value(for key: Key) -> String? {
        guard let entry = entries[key] else { return nil }
        markRecent(entry)
        return entry.output
    }

    func insert(_ output: String, for key: Key) {
        if let entry = entries[key] {
            entry.output = output
            markRecent(entry)
            return
        }

        if entries.count == capacity, let oldest {
            detach(oldest)
            entries.removeValue(forKey: oldest.key)
        }
        let entry = Entry(key: key, output: output)
        entries[key] = entry
        append(entry)
    }

    func removeAll() {
        oldest = nil
        newest = nil
        entries.removeAll()
    }

    private func markRecent(_ entry: Entry) {
        guard newest !== entry else { return }
        detach(entry)
        append(entry)
    }

    private func detach(_ entry: Entry) {
        let previous = entry.previous
        let next = entry.next
        previous?.next = next
        next?.previous = previous
        if oldest === entry { oldest = next }
        if newest === entry { newest = previous }
        entry.previous = nil
        entry.next = nil
    }

    private func append(_ entry: Entry) {
        entry.previous = newest
        newest?.next = entry
        newest = entry
        if oldest == nil { oldest = entry }
    }
}
