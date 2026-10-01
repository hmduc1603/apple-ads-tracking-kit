import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// Apple Search Ads campaign attribution for the K&D Labs reporting backend.
///
/// The app reports exactly one thing: once per install, the AdServices attribution token
/// together with a per-install `appAccountToken` UUID (`POST /api/attribution`). The backend
/// resolves the token into a campaign and stores it under that UUID.
///
/// Revenue is **not** reported by the app. Purchases, renewals and refunds reach the backend
/// from Apple as App Store Server Notifications, and Apple stamps each one with the
/// `appAccountToken` the app set on the purchase — that is the join between revenue and
/// campaign. So every purchase must carry it:
///
/// ```swift
/// AdTrackingKit.shared.start(config: AdTrackingConfig(
///     backendURL: URL(string: "https://reports.example.com")!,
///     apiKey: "…"
/// ))
///
/// let result = try await AdTrackingKit.shared.purchase(product)
/// // or: try await product.purchase(options: [AdTrackingKit.shared.appAccountTokenOption])
/// ```
public final class AdTrackingKit: @unchecked Sendable {
    public static let shared = AdTrackingKit()
    public static let sdkVersion = "2.0.0"

    private let lock = NSLock()
    private let store: AccountTokenStore
    private var config: AdTrackingConfig?
    private var reporter: AttributionReporter?
    private var foregroundObserver: NSObjectProtocol?

    init(store: AccountTokenStore = AccountTokenStore()) {
        self.store = store
    }

    // MARK: - Lifecycle

    /// Configure the kit and report this install's attribution if it hasn't been yet.
    ///
    /// Safe to call more than once; later calls are ignored. Until the backend acknowledges the
    /// report, the kit retries each time the app becomes active, then goes quiet for good.
    public func start(config: AdTrackingConfig) {
        lock.lock()
        guard self.config == nil else { lock.unlock(); return }
        self.config = config
        let reporter = AttributionReporter(
            client: AttributionAPIClient(config: config),
            store: store,
            log: { [weak self] in self?.log($0) }
        )
        self.reporter = reporter
        lock.unlock()

        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in
            Task.detached(priority: .utility) { _ = await reporter.reportIfNeeded() }
        }
        #endif

        Task.detached(priority: .utility) { _ = await reporter.reportIfNeeded() }
    }

    // MARK: - Purchases

    /// One UUID per install. Pass it to StoreKit on every purchase — `purchase(_:options:)` and
    /// `appAccountTokenOption` do that for you. Available before `start(config:)`.
    public var appAccountToken: UUID { store.appAccountToken }

    /// The StoreKit purchase option carrying `appAccountToken`, for apps that call
    /// `Product.purchase(options:)` themselves.
    public var appAccountTokenOption: Product.PurchaseOption { .appAccountToken(appAccountToken) }

    /// `product.purchase(options:)` with this install's `appAccountToken` attached, so the
    /// App Store Server Notifications for it can be tied back to the campaign.
    ///
    /// Does not finish the transaction; entitlement handling stays the host app's.
    public func purchase(
        _ product: Product,
        options: Set<Product.PurchaseOption> = []
    ) async throws -> Product.PurchaseResult {
        var options = options
        options.insert(appAccountTokenOption)
        return try await product.purchase(options: options)
    }

    // MARK: - Reporting

    /// Report this install's attribution now, if the backend hasn't acknowledged it yet.
    /// `start(config:)` already does this on launch and on foreground; call it directly only
    /// to await the outcome. Returns true once the backend has acknowledged the install.
    @discardableResult
    public func reportIfNeeded() async -> Bool {
        guard let reporter = currentReporter() else {
            log("reportIfNeeded called before start(config:) — ignoring.")
            return false
        }
        return await reporter.reportIfNeeded()
    }

    /// Whether the backend has acknowledged this install's attribution report.
    public var isAttributionReported: Bool { store.isReported }

    // MARK: - Internals

    private func currentReporter() -> AttributionReporter? {
        lock.lock()
        defer { lock.unlock() }
        return reporter
    }

    private func log(_ message: String) {
        lock.lock()
        let enabled = config?.loggingEnabled == true
        lock.unlock()
        guard enabled else { return }
        print("[AdTrackingKit] \(message)")
    }
}
