import Foundation

/// The per-install `appAccountToken`, persisted in UserDefaults.
///
/// The keys match the Swift snippet the dashboard shows (Apps → Configure), so an app that
/// started with the snippet keeps its token — and the attribution already stored against it —
/// when it moves to the kit.
///
/// UserDefaults rather than the Keychain on purpose: a reinstall is a new install as far as
/// AdServices is concerned, and should get a new token and a new attribution record.
struct AccountTokenStore: @unchecked Sendable {
    static let tokenKey = "kd.appAccountToken"
    static let reportedKey = "kd.attributionReported"

    let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appAccountToken: UUID {
        lock.lock()
        defer { lock.unlock() }
        if let saved = defaults.string(forKey: Self.tokenKey), let id = UUID(uuidString: saved) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Self.tokenKey)
        return id
    }

    var isReported: Bool {
        get { defaults.bool(forKey: Self.reportedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.reportedKey) }
    }
}

/// Sends the install's attribution report until the backend acknowledges it, then never again.
actor AttributionReporter {
    private let client: AttributionAPIClient
    private let store: AccountTokenStore
    private let tokenProvider: @Sendable () async -> String?
    private let log: @Sendable (String) -> Void

    private var inFlight: Task<Bool, Never>?
    /// Set when the backend refuses the report outright (bad key, unknown bundle id). Retrying
    /// on every foreground would fail identically, so it waits for the next launch instead.
    private var refusedThisSession = false

    init(
        client: AttributionAPIClient,
        store: AccountTokenStore,
        tokenProvider: @escaping @Sendable () async -> String? = { await AttributionTokenProvider.token() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.client = client
        self.store = store
        self.tokenProvider = tokenProvider
        self.log = log
    }

    /// True once the backend has acknowledged this install. Concurrent callers share one request.
    func reportIfNeeded() async -> Bool {
        if store.isReported { return true }
        if refusedThisSession { return false }
        if let inFlight { return await inFlight.value }

        let task = Task { await self.send() }
        inFlight = task
        let delivered = await task.value
        inFlight = nil
        return delivered
    }

    private func send() async -> Bool {
        let config = client.config
        guard !config.bundleId.isEmpty else {
            log("no bundle identifier — the backend can't match this install to an app. Pass `bundleId` explicitly.")
            return false
        }

        let attributionToken = await tokenProvider()
        if attributionToken == nil {
            // Still worth sending: the install is recorded as `no_token`, and its purchases
            // still show up in the dashboard as revenue — just not tied to a campaign.
            log("no attribution token available (simulator, or not an App Store install).")
        }

        let payload = AttributionPayload(
            bundleId: config.bundleId,
            appAccountToken: store.appAccountToken.uuidString,
            attributionToken: attributionToken,
            sdkVersion: AdTrackingKit.sdkVersion
        )

        do {
            let response = try await client.send(payload)
            store.isReported = true
            log("attribution reported (status: \(response.status ?? "unknown"), campaign: \(response.campaignId ?? "none"))")
            return true
        } catch AttributionReportError.http(let status, let body) {
            if (400..<500).contains(status) && status != 429 {
                refusedThisSession = true
            }
            log("backend refused attribution report: HTTP \(status) \(body)")
            return false
        } catch {
            log("attribution report failed, will retry: \(error)")
            return false
        }
    }
}
