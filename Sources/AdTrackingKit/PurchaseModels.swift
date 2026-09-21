import Foundation

/// What a purchase was: a first purchase, an auto-renewal, or a plan change.
public enum PurchaseEventType: String, Codable, Sendable {
    case purchase
    case renewal
    case upgrade
}

/// One purchase, bundled with the attribution token that resolves it back to the
/// Apple Search Ads campaign that drove the original install.
///
/// The token is fetched at purchase time rather than at install time: every token
/// AdServices issues on a device resolves to the *same* install attribution record for as
/// long as the app stays installed, so a token minted months after the download still names
/// the campaign that won it.
struct PurchasePayload: Codable, Sendable {
    let bundleId: String
    let deviceId: String
    let attributionToken: String?
    let attStatus: String
    let idfa: String?
    let idfv: String?
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let purchaseDate: Date
    let price: Double?
    let currencyCode: String?
    let eventType: String
    let isTrial: Bool
    let offerType: String?
    let environment: String
    let platform: String
    let sdkVersion: String

    init(
        bundleId: String,
        deviceId: String,
        attributionToken: String?,
        attStatus: String,
        idfa: String?,
        idfv: String?,
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        purchaseDate: Date,
        price: Double?,
        currencyCode: String?,
        eventType: PurchaseEventType,
        isTrial: Bool,
        offerType: String?,
        environment: String
    ) {
        self.bundleId = bundleId
        self.deviceId = deviceId
        self.attributionToken = attributionToken
        self.attStatus = attStatus
        self.idfa = idfa
        self.idfv = idfv
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.purchaseDate = purchaseDate
        self.price = price
        self.currencyCode = currencyCode
        self.eventType = eventType.rawValue
        self.isTrial = isTrial
        self.offerType = offerType
        self.environment = environment
        self.platform = "ios"
        self.sdkVersion = AdTrackingKit.sdkVersion
    }
}

struct PurchaseResponse: Codable, Sendable {
    let success: Bool
    let attributed: Bool?
    let deduped: Bool?
    let campaignId: String?
    let message: String?
}

/// Errors the kit surfaces to its own retry logic. None of these are thrown at the host app —
/// `reportPurchase` never throws, because a reporting failure must not affect a purchase flow.
enum AdTrackingError: Error {
    /// The backend rejected the payload permanently (4xx other than 429). Retrying won't help.
    case rejected(status: Int, body: String)
    /// Transport failure or a 5xx/429 — worth retrying later.
    case retryable(underlying: Error?)
    case notConfigured
}
