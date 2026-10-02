# AdTrackingKit

Apple Search Ads campaign attribution for iOS, reporting into the K&D Labs reporting backend.
It feeds the ROAS / Spend / Revenue per campaign view on the dashboard's App Detail page.

The app reports **one thing, once per install**: the AdServices attribution token, together
with a per-install `appAccountToken` UUID. Revenue is not reported by the app at all. Apple
delivers every purchase, renewal and refund to the backend as an App Store Server Notification,
and stamps each one with the `appAccountToken` the app set on the purchase. That UUID ties the
revenue to the campaign.

```
App launch (until acknowledged)
        │
        ▼
POST /api/attribution  { bundleId, appAccountToken, attributionToken }
        │               backend resolves the token with Apple → campaign, stored per UUID
        ▼
product.purchase(options: [.appAccountToken(uuid)])
        │
        ▼
Apple ──▶ POST /api/app-store/notifications/<per-app token>   (ASSN V2, signed JWS)
        │   every transaction carries the same appAccountToken
        ▼
Dashboard: revenue joined to campaign on appAccountToken
```

Renewals that happen while the app is closed are included, because Apple sends them
server-to-server.

## Requirements

- iOS 17+
- A real device for attribution. The simulator has no AdServices record, so a simulator
  install is reported as `no_token`. Its purchases still count as revenue, but without a
  campaign.
- On the backend: the app is registered (Apps tab), `INGEST_API_KEY` is set, and the app's
  App Store Server Notifications URL points at the backend (Apps → Configure).

## Install

Xcode → **File → Add Package Dependencies…** → paste the repository URL:

```
https://github.com/hmduc1603/apple-ads-tracking-kit
```

Or declare it in a `Package.swift`:

```swift
.package(url: "https://github.com/hmduc1603/apple-ads-tracking-kit.git", from: "2.0.0")
```

## Usage

### 1. Start the kit at launch

```swift
import AdTrackingKit
import SwiftUI

@main
struct YourApp: App {
    init() {
        AdTrackingKit.shared.start(config: AdTrackingConfig(
            backendURL: URL(string: "https://reports.example.com")!,
            apiKey: Secrets.adTrackingIngestKey   // matches the backend's INGEST_API_KEY
        ))
    }

    var body: some Scene { WindowGroup { ContentView() } }
}
```

The kit sends the report on launch and again each time the app becomes active, until the
backend acknowledges it. After that it sends nothing. A `202` reply (Apple hasn't provisioned
the record yet) counts as acknowledged, because the backend keeps resolving it on its own.

`bundleId` defaults to the host app's bundle identifier, which the backend matches against
its app registry.

### 2. Attach the appAccountToken to every purchase

Purchases without the token still show up as revenue, but they can't be tied to a campaign.

**Apps built on IOSBaseKit** buy through `PurchaseService`, which doesn't know about this kit.
Hand it the token at launch, next to `purchaseService.recorder = self`, and every
`purchaseService.purchase(product:isIntroSub:)` carries it from then on:

```swift
purchaseService.recorder = self
purchaseService.appAccountToken = AdTrackingKit.shared.appAccountToken
```

This needs IOSBaseKit `8b48374` or later. Without this line, attribution still reports, but no
revenue is ever tied to a campaign — an easy miss, since nothing fails.

Otherwise, let the kit make the purchase:

```swift
let result = try await AdTrackingKit.shared.purchase(product)
```

Or, if you call StoreKit yourself:

```swift
let result = try await product.purchase(options: [AdTrackingKit.shared.appAccountTokenOption])
```

With StoreKit 1, set `payment.applicationUsername = AdTrackingKit.shared.appAccountToken.uuidString`.
Apple carries a UUID-formatted `applicationUsername` through as the `appAccountToken`.

The kit never finishes transactions; handling entitlements is up to your app.

### Migrating from the dashboard snippet

The kit uses the same UserDefaults keys as the Swift snippet in Apps → Configure
(`kd.appAccountToken`, `kd.attributionReported`). If you replace the snippet with the kit,
existing installs keep their UUID and are not reported again.

### Migrating from 1.x

1.x reported each purchase to `POST /api/purchases`. That endpoint no longer exists.
`reportPurchase(_:)`, the transaction listener, the retry queue, ATT/IDFA collection and
`autoRequestATT` are gone. Remove any `reportPurchase` calls and pass the `appAccountToken` on
purchases instead (step 2).

## What gets sent

One JSON body per install: `bundleId`, `appAccountToken`, `attributionToken` (when the device
can produce one), and `sdkVersion`. It is sent with `Authorization: Bearer <INGEST_API_KEY>`.
The kit sends no IDFA, no IDFV and no purchase data.

The `appAccountToken` is stored in UserDefaults, not the Keychain, so a reinstall gets a fresh
UUID and a fresh attribution. That matches how AdServices treats a reinstall.

## Tests

```bash
xcodebuild test -scheme AdTrackingKit -destination 'platform=iOS Simulator,name=iPhone 17'
```
