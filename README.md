# SwiftIAP

Native **StoreKit 2** in-app-purchase toolkit — no third-party dependencies.
Extracted from the App653HealthTracker IAP system and generalized into a
reusable Swift package: the app-specific pieces (`AppProduct`,
`ConfigRemoteManager`, `ads_swift`, `NotificationManager`, `.localized`, and
the paywall UI) are now **injectable** behind small protocols with sensible
defaults.

## Requirements

- iOS 15+ / macOS 12+ (StoreKit 2)
- Swift 5.9+

## Install

Add the package in Xcode (File ▸ Add Package Dependencies…) pointing at this
repo, or in a `Package.swift`:

```swift
dependencies: [
    .package(path: "../swift-iap")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SwiftIAP", package: "swift-iap")
    ])
]
```

## Architecture

| Type | Role |
|------|------|
| `StoreContext` | `ObservableObject` StoreKit 2 wrapper: product list, transaction listener, purchase, restore. |
| `IAPHelper` | Singleton. Caches `isPremium` in `UserDefaults`; exposes `hasPremiumAccess` / `shouldGatePremium` — the single source of truth. |
| `IAPManager` | `@MainActor` singleton. Purchase / restore flow, loading + error state, auto re-validation on foreground. |
| `IAPSubscriptionHandler` | Detailed subscription state: expiring-soon, expired, revoked, grace period. |
| `FreeMeasureManager` | Optional free-tier usage limiter. |
| `IAPConfiguration` | **App-supplied config**: product catalog + injected services. |

```
IAPHelper.hasPremiumAccess
   = isPremium || !remoteConfig.getEnableIAP()
   → use this everywhere to check access.
```

## Configuration

Everything the package used to hard-code now lives in `IAPConfiguration`.
Call `configure(...)` **once**, before creating the store.

```swift
import SwiftIAP

enum AppProduct: String, InAppProduct, CaseIterable {
    case weekly = "com.myapp.weekly"
    case yearly = "com.myapp.yearly"
    var id: String { rawValue }
}

IAPConfiguration.shared.configure(
    premiumProductIds: AppProduct.allCases.map(\.id),
    // subscriptionProductIds: defaults to premium list

    // Optional — wire your remote config (Firebase, etc.):
    remoteConfig: ClosureIAPRemoteConfig(
        enableIAP: { RemoteConfig.remoteConfig()["iap_enable"].boolValue },
        freeMeasureLimit: { 3 },
        freeMeasureIntervalHours: { 24 }
    ),

    // Optional — bridge to your ads SDK (default: no-op):
    ads: ClosureIAPAdsBridging(
        setExcludeScreen: { AdsManager.shared.setExclude($0) },
        setShouldShowAds: { AdsManager.shared.setShouldShow($0) }
    ),

    // Optional — trial-ending local notifications (default: no-op):
    trialNotifications: ClosureTrialNotificationScheduler(
        schedule: { NotificationManager.shared.scheduleTrialEnd($0) },
        remove:   { NotificationManager.shared.removeTrialEnd() }
    ),

    // Optional — localization resolver (default: NSLocalizedString):
    localize: { NSLocalizedString($0, comment: "") },

    // Optional — namespace the UserDefaults cache per app:
    persistenceKeyPrefix: "com.myapp.iap",

    enableLogging: false
)
```

> Every provider is optional. With no arguments beyond `premiumProductIds`,
> the package runs standalone: IAP enabled, no ads, no notifications,
> `NSLocalizedString` for strings.

## App entry point

```swift
@main
struct MyApp: App {
    @StateObject private var store: StoreContext

    init() {
        IAPConfiguration.shared.configure(
            premiumProductIds: AppProduct.allCases.map(\.id)
        )
        _store = StateObject(wrappedValue: SwiftIAP.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}
```

`SwiftIAP.bootstrap()` wires `StoreContext` → `IAPHelper` → `IAPManager` in the
correct order and kicks off the initial StoreKit validation. (You can still do
it by hand — see the source of `SwiftIAP.bootstrap`.)

## Usage

### Check access (sync)

```swift
if IAPHelper.shared.hasPremiumAccess { /* unlocked */ }
if IAPHelper.shared.shouldGatePremium { /* show paywall */ }
```

### Purchase / restore

```swift
IAPManager.shared.purchase(product)   // drives the StoreKit payment sheet
IAPManager.shared.restorePurchases()
// observe IAPManager.shared.isLoading / .errorMessage / .showingPurchaseAlert
```

### Gate a view (blur + your own locked overlay)

```swift
myFeature
    .premiumGated {
        MyLockedOverlay(title: "EKG")   // your design, your assets
    }
```

### Free tier

```swift
guard FreeMeasureManager.shared.canMeasureFree() else { showPaywall = true; return }
performFeature()
FreeMeasureManager.shared.recordFreeMeasure()
Text("\(FreeMeasureManager.shared.getRemainingFreeMeasures()) left")
```

## Localization keys

Error/status strings resolve through `IAPConfiguration.localize`. Provide these
keys in your `.strings` (missing keys fall back to the key text):

```
network_connection_required, sign_in_apple_id_restore, app_store_unavailable,
store_configuration_error, purchase_verification_failed, restore_failed,
payment_issue, purchase_failed, restore_completed, no_purchases_found_to_restore,
purchase_pending_approval, purchase_failed_unknown, iap_sandbox_renewal_limit_reached,
subscription_revoked_by_apple, subscription_expires_in_days, subscription_is_active,
subscription_is_active_no_expiration, subscription_expired_on,
subscription_cancelled_but_active, no_subscription_found, unknown
```

## What changed vs. the original files

- `AppProduct.*` static arrays → `IAPConfiguration.premiumProductIds` / `.subscriptionProductIds`
- `ConfigRemoteManager.shared` → `IAPRemoteConfigProviding`
- `import ads_swift` / `AdsManager.shared` → `IAPAdsBridging` (no-op default)
- `NotificationManager.shared` → `IAPTrialNotificationScheduling` (no-op default)
- `String.localized` (global) → internal, routed through `IAPConfiguration.localize`
- Hard-coded `PremiumLockedView` / `IAPQuickView` / `PremiumButton` → generic `premiumGated { }` overlay (bring your own UI)
- Removed the unsafe `checkReceipt()` + `exit(173)` kill-switch and the app-specific `HeartRateMeasurementCache`
- Persistence keys are namespaced via `IAPConfiguration.persistenceKeyPrefix`

## License

Use freely within your own apps.
