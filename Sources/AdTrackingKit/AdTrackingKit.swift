import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// Purchase-triggered Apple Search Ads attribution.
///
/// Nothing is sent at install time. The attribution token is minted and delivered only when
/// StoreKit2 confirms a purchase, travelling to the backend in the same request as the
/// transaction — so there is no separate install-tracking call, and the campaign ↔ revenue
/// link is established in one hop.
///
/// Usage, once, from your `App` init or `application(_:didFinishLaunchingWithOptions:)`:
///
/// ```swift
/// AdTrackingKit.shared.start(config: AdTrackingConfig(
///     backendURL: URL(string: "https://reports.example.com")!,
///     apiKey: "…"
/// ))
/// ```
///
/// `start(config:)` installs its own `Transaction.updates` listener and sweeps
/// `Transaction.currentEntitlements`, so the host app does not need to forward anything by
/// hand. Call `reportPurchase(_:)` directly only if you already run your own listener and
/// would rather drive it yourself (pass `observeTransactions: false` to the config-less
/// `start` overload to avoid two listeners competing for the same transactions).
public final class AdTrackingKit: @unchecked Sendable {
    public static let shared = AdTrackingKit()
    public static let sdkVersion = "1.0.0"

    private let lock = NSLock()
    private var config: AdTrackingConfig?
    private var client: PurchaseAPIClient?
    private let queue = PendingPurchaseQueue()

    private var updatesTask: Task<Void, Never>?
    private var didStart = false

    private let deviceIdKey = "com.adtrackingkit.device.id"

    private init() {}

    // MARK: - Lifecycle

    /// Configure the kit and begin observing StoreKit2.
    ///
    /// Safe to call more than once; subsequent calls are ignored so a second call from a
    /// scene delegate can't start a second transaction listener.
    ///
    /// - Parameter observeTransactions: when false, the kit configures itself but installs no
    ///   `Transaction.updates` listener and runs no entitlements sweep — for apps that already
    ///   have a listener and will call `reportPurchase(_:)` themselves.
    public func start(config: AdTrackingConfig, observeTransactions: Bool = true) {
        lock.lock()
        guard !didStart else { lock.unlock(); return }
        didStart = true
        self.config = config
        self.client = PurchaseAPIClient(config: config)
        lock.unlock()

        if config.bundleId.isEmpty {
            log("no bundle identifier — purchases cannot be attributed to an app. Pass `bundleId` explicitly.")
        }

        if config.autoRequestATT {
            Task { _ = await ATTPermission.requestAuthorization() }
        }

        guard observeTransactions else { return }

        updatesTask = Task.detached(priority: .background) { [weak self] in
            await self?.flushPending()
            await self?.sweepCurrentEntitlements()
            await self?.observeTransactionUpdates()
        }
    }

    /// Stop observing StoreKit2. Mainly for tests and for apps that tear the kit down.
    public func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    // MARK: - Reporting

    /// Report one verified StoreKit2 transaction.
    ///
    /// Fetches a fresh attribution token and posts it together with the purchase. Never
    /// throws and never blocks: a reporting failure must not be able to disturb a purchase
    /// flow, so failures are persisted and retried on the next launch or foreground instead.
    ///
    /// Does **not** call `transaction.finish()` — entitlement lifecycle stays the host app's
    /// decision.
    public func reportPurchase(_ transaction: Transaction, eventType: PurchaseEventType? = nil) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.report(transaction, eventType: eventType)
        }
    }

    /// Async form of `reportPurchase(_:)`, for callers that want to await delivery.
    /// Returns true when the backend accepted (or deduplicated) the purchase.
    @discardableResult
    public func report(_ transaction: Transaction, eventType: PurchaseEventType? = nil) async -> Bool {
        guard let config = currentConfig() else {
            log("reportPurchase called before start(config:) — ignoring.")
            return false
        }

        let transactionId = String(transaction.id)
        if await queue.hasReported(transactionId) { return true }

        let payload = await makePayload(for: transaction, eventType: eventType, config: config)
        return await deliver(payload)
    }

    /// Re-send anything left in the retry queue. Call this when the app returns to the
    /// foreground if you want failed reports to recover without waiting for a relaunch.
    public func flushPending() async {
        guard currentConfig() != nil else { return }
        for payload in await queue.drainable() {
            await queue.recordAttempt(transactionId: payload.transactionId)
            _ = await deliver(payload)
        }
    }

    /// Report any current entitlement that hasn't been reported yet.
    ///
    /// Covers purchases made on another device, restored purchases, and sends that were
    /// interrupted before they completed. Already-reported transactions are skipped locally,
    /// so this is cheap on every launch after the first.
    public func sweepCurrentEntitlements() async {
        guard currentConfig() != nil else { return }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if await queue.hasReported(String(transaction.id)) { continue }
            _ = await report(transaction)
        }
    }

    // MARK: - Device id

    /// Stable per-install identifier, used as the join key between this purchase's
    /// attribution and anything else you record for the same device.
    ///
    /// Regenerates on reinstall, which is correct: a reinstall is a new install attribution
    /// as far as AdServices is concerned.
    public func persistentDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    // MARK: - Internals

    private func currentConfig() -> AdTrackingConfig? {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    private func currentClient() -> PurchaseAPIClient? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            _ = await report(transaction)
        }
    }

    /// Send, then either mark the transaction reported or park it for a later retry.
    private func deliver(_ payload: PurchasePayload) async -> Bool {
        guard let client = currentClient() else { return false }
        do {
            let response = try await client.send(payload)
            await queue.markReported(payload.transactionId)
            await queue.remove(transactionId: payload.transactionId)
            log("reported \(payload.transactionId) (attributed: \(response.attributed.map(String.init) ?? "pending"))")
            return true
        } catch AdTrackingError.rejected(let status, let body) {
            // Permanently refused — retrying would just fail identically every launch.
            await queue.remove(transactionId: payload.transactionId)
            log("backend rejected \(payload.transactionId): HTTP \(status) \(body)")
            return false
        } catch {
            await queue.enqueue(payload)
            log("deferred \(payload.transactionId) for retry: \(error)")
            return false
        }
    }

    private func makePayload(
        for transaction: Transaction,
        eventType: PurchaseEventType?,
        config: AdTrackingConfig
    ) async -> PurchasePayload {
        let token = await AttributionTokenProvider.token()
        if token == nil {
            // Still worth sending: the revenue is real even when the campaign link isn't
            // available (the simulator, or an install AdServices doesn't cover).
            log("no attribution token available — reporting purchase unattributed.")
        }

        let offer = transaction.adtk_offerDescription

        return PurchasePayload(
            bundleId: config.bundleId,
            deviceId: persistentDeviceId(),
            attributionToken: token,
            attStatus: ATTPermission.currentStatus().rawValue,
            idfa: ATTPermission.idfa(),
            idfv: Self.vendorId(),
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            productId: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            price: transaction.adtk_price,
            currencyCode: transaction.adtk_currencyCode,
            eventType: eventType ?? transaction.adtk_inferredEventType,
            isTrial: offer.isTrial,
            offerType: offer.type,
            environment: transaction.adtk_environment
        )
    }

    private static func vendorId() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    private func log(_ message: String) {
        guard currentConfig()?.loggingEnabled == true else { return }
        print("[AdTrackingKit] \(message)")
    }
}

// MARK: - StoreKit2 field extraction
//
// Kept out of the payload builder so that stays readable. `Transaction.offer` landed in 17.2,
// just after this package's deployment target, so it carries the one availability check left.

private extension Transaction {
    /// The amount actually charged, in the customer's currency.
    var adtk_price: Double? {
        guard let price else { return nil }
        return NSDecimalNumber(decimal: price).doubleValue
    }

    var adtk_currencyCode: String? { currency?.identifier }

    var adtk_environment: String { environment.rawValue }

    /// New purchase vs. auto-renewal vs. plan change, inferred when the caller doesn't say.
    var adtk_inferredEventType: PurchaseEventType {
        guard productType == .autoRenewable else { return .purchase }
        if isUpgraded { return .upgrade }
        // A renewal shares its `originalID` with the transaction that started the
        // subscription; only the first transaction has the two equal.
        return id == originalID ? .purchase : .renewal
    }

    var adtk_offerDescription: (isTrial: Bool, type: String?) {
        if #available(iOS 17.2, *) {
            guard let offer else { return (false, nil) }
            return (offer.paymentMode == .freeTrial, offer.type.adtk_label)
        }
        // Only 17.0 and 17.1 reach this. `offerType` is deprecated from 17.2 and carries no
        // payment mode, so an introductory offer is counted as a trial. Paid-intro offers are
        // rare enough that this beats losing free trials on those two releases.
        guard let offerType else { return (false, nil) }
        return (offerType == .introductory, offerType.adtk_label)
    }
}

private extension Transaction.OfferType {
    var adtk_label: String {
        switch self {
        case .introductory: return "introductory"
        case .promotional: return "promotional"
        case .code: return "code"
        // `.winBack` (iOS 18) and anything Apple adds later still report the offer's
        // presence rather than failing to compile against an older SDK.
        default: return "unknown"
        }
    }
}
