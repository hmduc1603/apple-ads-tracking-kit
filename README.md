# AdTrackingKit

Purchase-triggered Apple Search Ads attribution for iOS, reporting into the K&D Labs
reporting backend.

The attribution token is minted and sent **only when StoreKit2 confirms a purchase**, never at
install time. The token and the transaction travel in one request, so the backend can resolve
the campaign and store it alongside the revenue in a single write — no install-tracking step,
no revenue webhook.

```
StoreKit2 verifies a transaction
        │
        ▼
AdTrackingKit  ──  mints AAAttribution token, bundles it with the purchase
        │
        ▼
POST /api/purchases  ──▶  backend resolves the token against Apple's
                          attribution API and writes one purchase_events row
        │
        ▼
GET /api/asa/campaigns  ──▶  ROAS / Spend / Revenue per campaign in the dashboard
```

Why purchase-time minting works: `AAAttribution.attributionToken()` is not a session token.
Every token issued on a device resolves to the *same* install attribution record for as long as
the app stays installed — so a token fetched during a purchase months after the download still
names the campaign that won it.

## Requirements

- iOS 17+
- Works on a real device. The simulator has no AdServices attribution record, so purchases
  made there are reported unattributed.

## Install

Xcode → **File → Add Package Dependencies…** → paste the repository URL:

```
https://github.com/hmduc1603/apple-ads-tracking-kit
```

Or declare it in a `Package.swift`:

```swift
.package(url: "https://github.com/hmduc1603/apple-ads-tracking-kit.git", from: "1.0.0")
```

## Usage

One call. The kit installs its own `Transaction.updates` listener and sweeps
`Transaction.currentEntitlements` on launch, so there is nothing to forward by hand.

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

`bundleId` defaults to the host app's own bundle identifier, which is what the backend matches
against its app registry — so an app already visible in the dashboard needs no extra wiring.

### If you already run your own transaction listener

Tell the kit not to install a second one, and hand it transactions yourself:

```swift
AdTrackingKit.shared.start(config: config, observeTransactions: false)

for await result in Transaction.updates {
    guard case .verified(let transaction) = result else { continue }
    AdTrackingKit.shared.reportPurchase(transaction)
    await transaction.finish()
}
```

`reportPurchase(_:)` never throws and returns immediately. It does **not** call
`transaction.finish()` — entitlement lifecycle stays yours.

### Recovering failed sends sooner

Failed reports are persisted and retried on the next launch. To also retry on foreground:

```swift
.onChange(of: scenePhase) { phase in
    if phase == .active { Task { await AdTrackingKit.shared.flushPending() } }
}
```

### App Tracking Transparency

Not required. Apple Search Ads attribution via AdServices resolves regardless of ATT status, so
`autoRequestATT` defaults to `false` and the kit shows no prompt. Set it to `true` only if you
want the IDFA attached to purchases; the ATT status is reported either way.

## What gets sent

One JSON body per purchase: bundle id, a per-install device id, the attribution token, ATT
status, IDFA/IDFV when available, the StoreKit transaction ids, product id, purchase date,
price and currency, event type (`purchase` / `renewal` / `upgrade`), trial flag and offer type,
and the StoreKit environment.

Idempotency is on `transactionId`: the backend dedupes, and the kit keeps a local set of
already-reported ids so the launch-time entitlements sweep is cheap after the first run.

## Known gap: background renewals

`Transaction.updates` only fires while the app is running or is launched to process a
transaction. A subscription that auto-renews while the app stays closed will not be reported
through this path, so campaign ROAS under-reports renewal revenue. The fix is Apple's App Store
Server Notifications V2 (server-to-server, no client involvement); the backend's
`purchase_events` table is already shaped to accept those rows when that lands.

## Tests

```bash
swift test
```
