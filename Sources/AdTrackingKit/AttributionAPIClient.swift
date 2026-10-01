import Foundation

/// The body of `POST /api/attribution`.
struct AttributionPayload: Codable, Sendable, Equatable {
    let bundleId: String
    let appAccountToken: String
    let attributionToken: String?
    let sdkVersion: String
}

/// The backend's answer. `status` is the attribution state it stored: `resolved`, `organic`,
/// `no_token`, or — on a 202 — `pending` / `failed`, which the backend keeps retrying itself.
struct AttributionResponse: Codable, Sendable {
    let success: Bool?
    let status: String?
    let campaignId: String?
    let deduped: Bool?
    let message: String?
}

enum AttributionReportError: Error {
    /// The backend answered with a non-2xx status.
    case http(status: Int, body: String)
    case transport(Error)
    case encoding(Error)
}

/// Posts the install's attribution report to the reporting backend.
struct AttributionAPIClient: Sendable {
    let config: AdTrackingConfig
    let session: URLSession

    init(config: AdTrackingConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func makeRequest(_ payload: AttributionPayload) throws -> URLRequest {
        var request = URLRequest(url: config.backendURL.appendingPathComponent("api/attribution"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw AttributionReportError.encoding(error)
        }
        return request
    }

    /// Send the report. Any 2xx counts as delivered — including 202, which means the backend
    /// stored it and will resolve the campaign on its own schedule; the app must not resend.
    @discardableResult
    func send(_ payload: AttributionPayload) async throws -> AttributionResponse {
        let request = try makeRequest(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AttributionReportError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AttributionReportError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        return (try? JSONDecoder().decode(AttributionResponse.self, from: data))
            ?? AttributionResponse(success: true, status: nil, campaignId: nil, deduped: nil, message: nil)
    }
}
