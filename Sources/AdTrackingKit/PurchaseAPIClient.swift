import Foundation

/// Posts purchase payloads to the reporting backend.
actor PurchaseAPIClient {
    private let config: AdTrackingConfig
    private let session: URLSession

    init(config: AdTrackingConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Send one purchase. Throws `AdTrackingError.retryable` for anything worth trying again
    /// (transport failure, 5xx, 429) and `.rejected` for a permanent refusal, so the caller
    /// knows whether to keep the payload in the retry queue or drop it.
    @discardableResult
    func send(_ payload: PurchasePayload) async throws -> PurchaseResponse {
        var request = URLRequest(url: config.backendURL.appendingPathComponent("api/purchases"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        do {
            request.httpBody = try Self.encoder.encode(payload)
        } catch {
            // An unencodable payload will never encode. Dropping it beats retrying forever.
            throw AdTrackingError.rejected(status: 0, body: "encoding failed: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AdTrackingError.retryable(underlying: error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // 429 and 5xx are transient; every other 4xx means this payload is not acceptable
            // and never will be (bad key, unknown bundle id, malformed fields).
            if status == 429 || status >= 500 {
                throw AdTrackingError.retryable(underlying: nil)
            }
            throw AdTrackingError.rejected(status: status, body: body)
        }

        // The backend answers 202 with a body on the "stored but not yet attributed" path,
        // so an undecodable body on a 2xx still counts as delivered.
        return (try? JSONDecoder().decode(PurchaseResponse.self, from: data))
            ?? PurchaseResponse(success: true, attributed: nil, deduped: nil, campaignId: nil, message: nil)
    }
}
