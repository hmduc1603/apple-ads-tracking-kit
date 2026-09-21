import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Mints Apple Search Ads attribution tokens.
///
/// `AAAttribution.attributionToken()` is not a session token: every token it issues on a given
/// device resolves — server-side, against Apple's attribution API — to the same install
/// attribution record, for as long as the app remains installed. That is what makes
/// purchase-time minting work: a token fetched at the moment of a purchase months after the
/// download still names the campaign that drove that download.
enum AttributionTokenProvider {
    /// A fresh token, or nil when the device can't provide one — the simulator, or an app
    /// installed by a route AdServices doesn't cover.
    ///
    /// Token generation does synchronous work, so it is kept off the caller's thread.
    static func token() async -> String? {
        #if canImport(AdServices)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: try? AAAttribution.attributionToken())
            }
        }
        #else
        return nil
        #endif
    }
}
