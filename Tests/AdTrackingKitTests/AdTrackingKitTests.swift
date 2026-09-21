import XCTest
@testable import AdTrackingKit

final class AdTrackingKitTests: XCTestCase {

    func testDeviceIdIsStableAcrossCalls() {
        let first = AdTrackingKit.shared.persistentDeviceId()
        let second = AdTrackingKit.shared.persistentDeviceId()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testConfigDefaultsToHostBundleIdentifier() {
        let config = AdTrackingConfig(
            backendURL: URL(string: "https://example.com")!,
            apiKey: "test-key"
        )
        XCTAssertEqual(config.bundleId, Bundle.main.bundleIdentifier ?? "")
        // ATT must not be requested unless the host app opts in — AdServices attribution
        // does not depend on it.
        XCTAssertFalse(config.autoRequestATT)
    }

    func testPayloadEncodesISO8601DatesAndTrialFlag() throws {
        let payload = PurchasePayload(
            bundleId: "com.example.app",
            deviceId: "device-1",
            attributionToken: "token-1",
            attStatus: ATTStatus.denied.rawValue,
            idfa: nil,
            idfv: "vendor-1",
            transactionId: "2000000001",
            originalTransactionId: "2000000000",
            productId: "pro.monthly",
            purchaseDate: Date(timeIntervalSince1970: 1_700_000_000),
            price: 9.99,
            currencyCode: "USD",
            eventType: .renewal,
            isTrial: true,
            offerType: "introductory",
            environment: "Production"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try JSONSerialization.jsonObject(with: encoder.encode(payload)) as! [String: Any]

        XCTAssertEqual(json["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(json["eventType"] as? String, "renewal")
        XCTAssertEqual(json["isTrial"] as? Bool, true)
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["sdkVersion"] as? String, AdTrackingKit.sdkVersion)
        XCTAssertEqual(json["purchaseDate"] as? String, "2023-11-14T22:13:20Z")
        // A nil IDFA must be absent or null, never the all-zero UUID.
        XCTAssertNil(json["idfa"] as? String)
    }

    func testQueueDeduplicatesAndDrains() async {
        let queue = PendingPurchaseQueue(suiteName: "com.adtrackingkit.tests.\(UUID().uuidString)")
        let payload = Self.samplePayload(transactionId: "tx-1")

        await queue.enqueue(payload)
        await queue.enqueue(payload) // same transaction — must not double up
        let drainable = await queue.drainable()
        XCTAssertEqual(drainable.count, 1)

        await queue.remove(transactionId: "tx-1")
        let afterRemoval = await queue.drainable()
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testReportedTransactionsAreRemembered() async {
        let queue = PendingPurchaseQueue(suiteName: "com.adtrackingkit.tests.\(UUID().uuidString)")
        let hasBefore = await queue.hasReported("tx-2")
        XCTAssertFalse(hasBefore)

        await queue.markReported("tx-2")
        let hasAfter = await queue.hasReported("tx-2")
        XCTAssertTrue(hasAfter)
    }

    private static func samplePayload(transactionId: String) -> PurchasePayload {
        PurchasePayload(
            bundleId: "com.example.app",
            deviceId: "device-1",
            attributionToken: "token",
            attStatus: ATTStatus.notDetermined.rawValue,
            idfa: nil,
            idfv: nil,
            transactionId: transactionId,
            originalTransactionId: transactionId,
            productId: "pro.yearly",
            purchaseDate: Date(),
            price: 49.99,
            currencyCode: "USD",
            eventType: .purchase,
            isTrial: false,
            offerType: nil,
            environment: "Sandbox"
        )
    }
}
