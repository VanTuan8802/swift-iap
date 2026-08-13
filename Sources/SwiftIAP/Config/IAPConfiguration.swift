//
//  IAPConfiguration.swift
//  SwiftIAP
//
//  Central, app-supplied configuration. This replaces the hard-coded
//  `AppProduct` static arrays and the singleton service references that the
//  original files reached into directly.
//
//  Call `IAPConfiguration.configure(...)` exactly once, early in app launch
//  (before creating `StoreContext` / calling `IAPManager.setup()`).
//

import Foundation

/// Global configuration for the SwiftIAP package.
///
/// Thread-safety: intended to be configured once at launch and only read
/// afterwards. Reads happen from both the main actor and background tasks
/// (transaction listener), hence `@unchecked Sendable`.
public final class IAPConfiguration: @unchecked Sendable {

    /// The shared configuration used by all package singletons.
    public static let shared = IAPConfiguration()

    // MARK: Product catalog

    /// Product IDs that grant premium access (any valid transaction here → premium).
    public var premiumProductIds: [String] = []

    /// Product IDs treated as auto-renewable subscriptions (upgrade/switch logic).
    public var subscriptionProductIds: [String] = []

    // MARK: Injected services

    public var remoteConfig: IAPRemoteConfigProviding = DefaultIAPRemoteConfig()
    public var ads: IAPAdsBridging = NoopIAPAdsBridging()
    public var trialNotifications: IAPTrialNotificationScheduling = NoopTrialNotificationScheduler()

    // MARK: Localization

    /// Resolves a localization key to a display string. Defaults to
    /// `NSLocalizedString`, so keys resolve against the host app's `.strings`
    /// files (falling back to the key itself when no translation exists).
    public var localize: @Sendable (String) -> String = { key in
        NSLocalizedString(key, comment: "")
    }

    // MARK: Logging

    /// When `true`, the package prints its verbose diagnostic logs (the many
    /// `print("✅ …")` statements from the original code). Off by default.
    public var isLoggingEnabled: Bool = false

    /// Namespace prefix for the `UserDefaults` keys used to persist the
    /// `StoreContext` cache. Set a per-app value to avoid collisions when two
    /// apps share the package.
    public var persistenceKeyPrefix: String = "swiftiap.storekit"

    private init() {}

    // MARK: - Configuration entry point

    /// Configure the package. Call once at app launch.
    ///
    /// - Parameters:
    ///   - premiumProductIds: product IDs that unlock premium.
    ///   - subscriptionProductIds: auto-renewable subscription IDs. Defaults to
    ///     `premiumProductIds` when omitted (the common case).
    ///   - remoteConfig: IAP master switch + free-tier limits.
    ///   - ads: optional ads SDK bridge.
    ///   - trialNotifications: optional trial-expiration notification bridge.
    ///   - localize: optional localization resolver.
    ///   - persistenceKeyPrefix: optional `UserDefaults` namespace.
    ///   - enableLogging: verbose diagnostics toggle.
    public func configure(
        premiumProductIds: [String],
        subscriptionProductIds: [String]? = nil,
        remoteConfig: IAPRemoteConfigProviding = DefaultIAPRemoteConfig(),
        ads: IAPAdsBridging = NoopIAPAdsBridging(),
        trialNotifications: IAPTrialNotificationScheduling = NoopTrialNotificationScheduler(),
        localize: (@Sendable (String) -> String)? = nil,
        persistenceKeyPrefix: String? = nil,
        enableLogging: Bool = false
    ) {
        self.premiumProductIds = premiumProductIds
        self.subscriptionProductIds = subscriptionProductIds ?? premiumProductIds
        self.remoteConfig = remoteConfig
        self.ads = ads
        self.trialNotifications = trialNotifications
        if let localize { self.localize = localize }
        if let persistenceKeyPrefix { self.persistenceKeyPrefix = persistenceKeyPrefix }
        self.isLoggingEnabled = enableLogging
    }

    /// Convenience overload that derives the catalog from an `InAppProduct` enum.
    public func configure<P: InAppProduct>(
        products: P.Type,
        premium: (P) -> Bool = { _ in true },
        subscription: ((P) -> Bool)? = nil,
        remoteConfig: IAPRemoteConfigProviding = DefaultIAPRemoteConfig(),
        ads: IAPAdsBridging = NoopIAPAdsBridging(),
        trialNotifications: IAPTrialNotificationScheduling = NoopTrialNotificationScheduler(),
        localize: (@Sendable (String) -> String)? = nil,
        persistenceKeyPrefix: String? = nil,
        enableLogging: Bool = false
    ) {
        let all = Array(P.allCases)
        let premiumIds = all.filter(premium).map { $0.id }
        let subscriptionIds = subscription.map { pred in all.filter(pred).map { $0.id } }
        configure(
            premiumProductIds: premiumIds,
            subscriptionProductIds: subscriptionIds,
            remoteConfig: remoteConfig,
            ads: ads,
            trialNotifications: trialNotifications,
            localize: localize,
            persistenceKeyPrefix: persistenceKeyPrefix,
            enableLogging: enableLogging
        )
    }
}

// MARK: - Internal conveniences

extension String {
    /// Package-internal localization, routed through `IAPConfiguration.localize`.
    /// Kept internal so it never clashes with a host app's own `String.localized`.
    var localized: String { IAPConfiguration.shared.localize(self) }
}

/// Package-internal logger gated by `IAPConfiguration.isLoggingEnabled`.
@inline(__always)
func iapLog(_ message: @autoclosure () -> String) {
    if IAPConfiguration.shared.isLoggingEnabled {
        print(message())
    }
}
