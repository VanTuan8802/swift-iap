//
//  IAPProviders.swift
//  SwiftIAP
//
//  Injection points that decouple the package from an app's concrete
//  services. In the original code base these were hard-wired singletons:
//    - `ConfigRemoteManager.shared`   → `IAPRemoteConfigProviding`
//    - `AdsManager.shared`            → `IAPAdsBridging`
//    - `NotificationManager.shared`   → `IAPTrialNotificationScheduling`
//
//  Every provider ships with a default implementation, so a host app only
//  needs to override the ones it actually cares about.
//

import Foundation

// MARK: - Remote config

/// Supplies the three remote-config values the IAP system reads.
public protocol IAPRemoteConfigProviding: Sendable {
    /// Master switch for IAP. When `false`, `IAPHelper.hasPremiumAccess` is
    /// always `true` (used for App Store review builds / kill-switch).
    func getEnableIAP() -> Bool
    /// Number of free uses allowed per interval (used by `FreeMeasureManager`).
    func getFreeMeasureLimitPerInterval() -> Int
    /// Length of the free-usage interval, in hours.
    func getFreeMeasureTimeInterval() -> Int
}

/// Default remote config: IAP enabled, 3 free uses per 24 h.
public struct DefaultIAPRemoteConfig: IAPRemoteConfigProviding {
    public var enableIAP: Bool
    public var freeMeasureLimit: Int
    public var freeMeasureIntervalHours: Int

    public init(
        enableIAP: Bool = true,
        freeMeasureLimit: Int = 3,
        freeMeasureIntervalHours: Int = 24
    ) {
        self.enableIAP = enableIAP
        self.freeMeasureLimit = freeMeasureLimit
        self.freeMeasureIntervalHours = freeMeasureIntervalHours
    }

    public func getEnableIAP() -> Bool { enableIAP }
    public func getFreeMeasureLimitPerInterval() -> Int { freeMeasureLimit }
    public func getFreeMeasureTimeInterval() -> Int { freeMeasureIntervalHours }
}

/// Convenience provider driven by closures, so a host app can wire Firebase
/// Remote Config (or anything else) without declaring a new type.
public struct ClosureIAPRemoteConfig: IAPRemoteConfigProviding {
    private let enableIAP: @Sendable () -> Bool
    private let freeLimit: @Sendable () -> Int
    private let interval: @Sendable () -> Int

    public init(
        enableIAP: @escaping @Sendable () -> Bool,
        freeMeasureLimit: @escaping @Sendable () -> Int = { 3 },
        freeMeasureIntervalHours: @escaping @Sendable () -> Int = { 24 }
    ) {
        self.enableIAP = enableIAP
        self.freeLimit = freeMeasureLimit
        self.interval = freeMeasureIntervalHours
    }

    public func getEnableIAP() -> Bool { enableIAP() }
    public func getFreeMeasureLimitPerInterval() -> Int { freeLimit() }
    public func getFreeMeasureTimeInterval() -> Int { interval() }
}

// MARK: - Ads bridging

/// Lets the IAP flow tell an ads SDK to suspend / permanently hide ads while
/// a purchase or restore is in progress. Optional — default is a no-op.
public protocol IAPAdsBridging: Sendable {
    /// Exclude the current screen from interstitial/app-open ads (called when a
    /// purchase/restore starts, and reset when it fails or is cancelled).
    func setExcludeScreen(_ exclude: Bool)
    /// Permanently enable/disable ads (called with `false` once the user is premium).
    func setShouldShowAds(_ shouldShow: Bool)
}

/// Ads bridge that does nothing. Use when the app has no ads.
public struct NoopIAPAdsBridging: IAPAdsBridging {
    public init() {}
    public func setExcludeScreen(_ exclude: Bool) {}
    public func setShouldShowAds(_ shouldShow: Bool) {}
}

/// Closure-driven ads bridge for quick wiring to an existing ads SDK.
public struct ClosureIAPAdsBridging: IAPAdsBridging {
    private let exclude: @Sendable (Bool) -> Void
    private let shouldShow: @Sendable (Bool) -> Void

    public init(
        setExcludeScreen: @escaping @Sendable (Bool) -> Void = { _ in },
        setShouldShowAds: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.exclude = setExcludeScreen
        self.shouldShow = setShouldShowAds
    }

    public func setExcludeScreen(_ exclude: Bool) { self.exclude(exclude) }
    public func setShouldShowAds(_ shouldShow: Bool) { self.shouldShow(shouldShow) }
}

// MARK: - Trial notifications

/// Lets the IAP flow schedule / cancel a "free trial ending soon" local
/// notification. Optional — default is a no-op.
public protocol IAPTrialNotificationScheduling: Sendable {
    func scheduleFreeTrialExpirationNotification(expirationDate: Date)
    func removeFreeTrialNotification()
}

/// Trial-notification scheduler that does nothing.
public struct NoopTrialNotificationScheduler: IAPTrialNotificationScheduling {
    public init() {}
    public func scheduleFreeTrialExpirationNotification(expirationDate: Date) {}
    public func removeFreeTrialNotification() {}
}

/// Closure-driven trial-notification scheduler.
public struct ClosureTrialNotificationScheduler: IAPTrialNotificationScheduling {
    private let schedule: @Sendable (Date) -> Void
    private let remove: @Sendable () -> Void

    public init(
        schedule: @escaping @Sendable (Date) -> Void,
        remove: @escaping @Sendable () -> Void = {}
    ) {
        self.schedule = schedule
        self.remove = remove
    }

    public func scheduleFreeTrialExpirationNotification(expirationDate: Date) { schedule(expirationDate) }
    public func removeFreeTrialNotification() { remove() }
}
