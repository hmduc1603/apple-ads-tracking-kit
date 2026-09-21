import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif

/// App Tracking Transparency authorization state, as a stable string for the backend.
public enum ATTStatus: String, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case unavailable
}

/// ATT is *not* required for Apple Search Ads attribution — AdServices resolves campaigns
/// regardless of consent. This exists only so the backend can record the state, and so the
/// IDFA can ride along when the user has already opted in.
enum ATTPermission {
    static func requestAuthorization() async -> ATTStatus {
        #if canImport(AppTrackingTransparency)
        let status = await ATTrackingManager.requestTrackingAuthorization()
        return map(status)
        #else
        return .unavailable
        #endif
    }

    static func currentStatus() -> ATTStatus {
        #if canImport(AppTrackingTransparency)
        return map(ATTrackingManager.trackingAuthorizationStatus)
        #else
        return .unavailable
        #endif
    }

    /// The advertising identifier, or nil unless the user has explicitly authorized tracking.
    /// Apple returns an all-zero UUID when unauthorized; that is filtered out rather than sent.
    static func idfa() -> String? {
        #if canImport(AdSupport)
        guard currentStatus() == .authorized else { return nil }
        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return id == "00000000-0000-0000-0000-000000000000" ? nil : id
        #else
        return nil
        #endif
    }

    #if canImport(AppTrackingTransparency)
    private static func map(_ status: ATTrackingManager.AuthorizationStatus) -> ATTStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unavailable
        }
    }
    #endif
}
