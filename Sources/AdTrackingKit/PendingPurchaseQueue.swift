import Foundation

/// On-disk store of purchases that haven't reached the backend yet, plus the ids of the ones
/// that have.
///
/// StoreKit2 redelivers transactions that were never `finish()`ed, but host apps routinely
/// finish a transaction immediately after handing it to us — so relying on redelivery alone
/// loses revenue whenever the network is down at that moment. Failed sends are persisted here
/// and flushed on the next launch or foreground.
///
/// Both sets live in Application Support (excluded from iCloud backup is unnecessary — these
/// are small and re-derivable), not UserDefaults, so a large backlog can't bloat the app's
/// preference plist.
actor PendingPurchaseQueue {
    private let directory: URL
    private let pendingURL: URL
    private let reportedURL: URL

    /// A failed payload is retried until it succeeds, is permanently rejected, or ages out.
    /// Apple's attribution record is only guaranteed for a limited window and stale revenue
    /// is worth less than an unbounded queue.
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let maxPending = 200
    private static let maxReported = 1000

    private var pending: [StoredPayload] = []
    private var reported: [String] = []
    private var loaded = false

    struct StoredPayload: Codable {
        let payload: PurchasePayload
        let firstQueuedAt: Date
        var attempts: Int
    }

    init(suiteName: String = "com.adtrackingkit") {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent(suiteName, isDirectory: true)
        self.pendingURL = directory.appendingPathComponent("pending-purchases.json")
        self.reportedURL = directory.appendingPathComponent("reported-transactions.json")
    }

    // MARK: - Reported transaction ids

    /// Whether this transaction has already been delivered, so the launch-time entitlements
    /// sweep doesn't re-send every past purchase on every cold start. The backend dedupes on
    /// `transactionId` too — this just spares the round trips.
    func hasReported(_ transactionId: String) -> Bool {
        load()
        return reported.contains(transactionId)
    }

    func markReported(_ transactionId: String) {
        load()
        guard !reported.contains(transactionId) else { return }
        reported.append(transactionId)
        if reported.count > Self.maxReported {
            reported.removeFirst(reported.count - Self.maxReported)
        }
        persistReported()
    }

    // MARK: - Pending payloads

    func enqueue(_ payload: PurchasePayload) {
        load()
        guard !pending.contains(where: { $0.payload.transactionId == payload.transactionId }) else { return }
        pending.append(StoredPayload(payload: payload, firstQueuedAt: Date(), attempts: 1))
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
        }
        persistPending()
    }

    func remove(transactionId: String) {
        load()
        pending.removeAll { $0.payload.transactionId == transactionId }
        persistPending()
    }

    func recordAttempt(transactionId: String) {
        load()
        guard let index = pending.firstIndex(where: { $0.payload.transactionId == transactionId }) else { return }
        pending[index].attempts += 1
        persistPending()
    }

    /// Everything still worth sending, oldest first. Expired entries are dropped here rather
    /// than on a timer, so the queue only ever shrinks when something actually reads it.
    func drainable() -> [PurchasePayload] {
        load()
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let expired = pending.filter { $0.firstQueuedAt < cutoff }
        if !expired.isEmpty {
            pending.removeAll { $0.firstQueuedAt < cutoff }
            persistPending()
        }
        return pending.map(\.payload)
    }

    // MARK: - Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: pendingURL),
           let decoded = try? decoder.decode([StoredPayload].self, from: data) {
            pending = decoded
        }
        if let data = try? Data(contentsOf: reportedURL),
           let decoded = try? decoder.decode([String].self, from: data) {
            reported = decoded
        }
    }

    private func persistPending() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(pending) else { return }
        try? data.write(to: pendingURL, options: .atomic)
    }

    private func persistReported() {
        guard let data = try? JSONEncoder().encode(reported) else { return }
        try? data.write(to: reportedURL, options: .atomic)
    }
}
