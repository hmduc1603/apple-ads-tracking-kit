import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Mints Apple Search Ads attribution tokens.
///
/// The backend resolves the token against Apple's attribution API (`api-adservices.apple.com`)
/// into the campaign that drove the install, and keeps retrying there while Apple hasn't
/// provisioned the record yet — so the app only has to produce a token once.
enum AttributionTokenProvider {
    /// Apple documents `attributionToken()` as able to fail transiently; a couple of short
    /// retries recover those without waiting for the next launch.
    private static let retryDelays: [UInt64] = [500_000_000, 1_500_000_000]

    /// A token, or nil when the device can't provide one — the simulator, or an app
    /// installed by a route AdServices doesn't cover.
    static func token() async -> String? {
        #if canImport(AdServices)
        if let token = await mint() { return token }
        for delay in retryDelays {
            try? await Task.sleep(nanoseconds: delay)
            if let token = await mint() { return token }
        }
        #endif
        return nil
    }

    #if canImport(AdServices)
    /// Token generation does synchronous work, so it is kept off the caller's thread.
    private static func mint() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: try? AAAttribution.attributionToken())
            }
        }
    }
    #endif
}
