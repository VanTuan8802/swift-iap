//
//  IAPHelper.swift
//  SwiftIAP
//
//  Single source of truth for "does the user have premium access". Backed by a
//  fast UserDefaults cache and validated against StoreKit 2 on launch / after
//  every purchase or restore.
//

import Foundation

public final class IAPHelper: ObservableObject {
    public static let shared = IAPHelper()
    private var store: StoreContext?

    private init() {}

    // MARK: - StoreContext binding

    public func setStoreContext(_ storeContext: StoreContext) {
        self.store = storeContext
        refreshFromCache()
    }

    // MARK: - Premium Status (sync, reads UserDefaults cache)

    /// Fast synchronous check backed by UserDefaults cache.
    /// Always up-to-date as long as `refreshFromStoreKit()` is called on app launch
    /// and whenever a purchase / restore completes.
    public var isPremium: Bool {
        UserDefaults.standard.bool(forKey: IAPUserDefaultsKeys.isPremium)
    }

    // MARK: - Centralized Access Rules

    /// `true` if the user has an active subscription **or** IAP is disabled via remote config.
    public var hasPremiumAccess: Bool {
        isPremium || !IAPConfiguration.shared.remoteConfig.getEnableIAP()
    }

    /// `true` if a premium feature should show the paywall. Inverse of `hasPremiumAccess`.
    public var shouldGatePremium: Bool { !hasPremiumAccess }

    public var shouldShowAds: Bool { !isPremium }

    // MARK: - Cache refresh (sync)

    /// Writes the cached `isPremium` value back to UserDefaults so non-async code
    /// can read it without hitting StoreKit.
    public func refreshFromCache() {
        UserDefaults.standard.set(isPremium, forKey: IAPUserDefaultsKeys.isPremium)
    }

    // MARK: - StoreKit refresh (async)

    /// Validates all premium product transactions against StoreKit 2 and
    /// updates the UserDefaults cache. Call on app launch and after every
    /// purchase / restore.
    public func refreshFromStoreKit() async {
        let result = await isPremiumAsync()
        UserDefaults.standard.set(result, forKey: IAPUserDefaultsKeys.isPremium)
    }

    // MARK: - Async validation

    /// Hits StoreKit 2 directly to verify whether the user owns a valid
    /// premium subscription. Updates the cache on success.
    public func isPremiumAsync() async -> Bool {
        await waitForStoreContextSync()

        guard let store else { return false }

        for productId in IAPConfiguration.shared.premiumProductIds {
            do {
                if let transaction = try await store.getValidTransaction(for: productId),
                   transaction.isValid {
                    UserDefaults.standard.set(true, forKey: IAPUserDefaultsKeys.isPremium)
                    return true
                }
            } catch {
                iapLog("❌ IAP validation error for \(productId): \(error)")
            }
        }

        UserDefaults.standard.set(false, forKey: IAPUserDefaultsKeys.isPremium)
        return false
    }

    // MARK: - StoreContext helpers

    public func isStoreContextReady() -> Bool {
        guard let store else { return false }
        return !store.products.isEmpty
    }

    // MARK: - Private

    /// Waits (up to 10 s) for `StoreContext` to finish loading products on
    /// first launch. Uses exponential back-off instead of a fixed 100 ms poll.
    private func waitForStoreContextSync() async {
        guard let store, store.products.isEmpty else { return }

        var delay: UInt64 = 100_000_000 // 0.1 s
        let deadline = Date().addingTimeInterval(10)

        while store.products.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 1_000_000_000) // cap at 1 s
        }
    }
}
