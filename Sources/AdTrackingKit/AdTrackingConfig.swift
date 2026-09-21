import Foundation

/// Everything the kit needs to talk to the reporting backend.
///
/// `bundleId` defaults to the host app's own bundle identifier, which is what the backend
/// resolves against `apps.bundle_id` to find the app's `app_key` (Apple's adamId). Pass it
/// explicitly only if the app ships under a bundle id the dashboard doesn't know about.
public struct AdTrackingConfig {
    /// Base URL of the reporting backend, e.g. `https://reports.example.com`.
    /// Path components are appended to this, so a trailing slash is harmless.
    public let backendURL: URL

    /// Bundle identifier reported to the backend. Defaults to `Bundle.main.bundleIdentifier`.
    public let bundleId: String

    /// Shared secret matching the backend's `INGEST_API_KEY`. Sent as a Bearer token.
    public let apiKey: String

    /// Whether `start(config:)` should show the App Tracking Transparency prompt.
    ///
    /// Defaults to `false`: Apple Search Ads attribution via AdServices works regardless of
    /// ATT status, so the kit has no reason to make the host app ask for consent it may not
    /// want to ask for yet. Set to `true` only if you also want the IDFA attached to purchases.
    public let autoRequestATT: Bool

    /// Emit `[AdTrackingKit]` diagnostics to the console.
    public let loggingEnabled: Bool

    public init(
        backendURL: URL,
        apiKey: String,
        bundleId: String = Bundle.main.bundleIdentifier ?? "",
        autoRequestATT: Bool = false,
        loggingEnabled: Bool = false
    ) {
        self.backendURL = backendURL
        self.bundleId = bundleId
        self.apiKey = apiKey
        self.autoRequestATT = autoRequestATT
        self.loggingEnabled = loggingEnabled
    }
}
