//
//  IAPManager.swift
//  SwiftIAP
//
//  Drives the purchase / restore flows, loading + error state, and automatic
//  subscription re-validation on app foreground. Ads and trial notifications
//  are decoupled behind `IAPConfiguration` providers.
//

import Foundation
import SwiftUI
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class IAPManager: ObservableObject {
    public static let shared = IAPManager()

    // MARK: - Published Properties
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var showingPurchaseAlert = false
    @Published public var selectedProduct: Product?
    @Published public var restoreSuccessful = false

    // MARK: - Store Context Reference
    private var store: StoreContext?

    // MARK: - Handlers
    private var subscriptionHandler: IAPSubscriptionHandler?

    // Convenience accessors for injected services.
    private var ads: IAPAdsBridging { IAPConfiguration.shared.ads }
    private var trialNotifications: IAPTrialNotificationScheduling { IAPConfiguration.shared.trialNotifications }

    private init() {}

    // MARK: - Setup
    public func setup() {
        iapLog("✅ SwiftIAP setup started")

        subscriptionHandler = IAPSubscriptionHandler(store: store)

        Task { await checkAndUpdateSubscriptionStatus() }

        setupAutomaticSubscriptionChecking()
    }

    // MARK: - Setup Automatic Subscription Checking
    private func setupAutomaticSubscriptionChecking() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.forceRefreshSubscriptionStatus() }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.forceRefreshSubscriptionStatus() }
        }
        iapLog("🔔 Automatic subscription checking setup completed")
        #endif
    }

    // MARK: - Force Refresh Subscription Status
    public func forceRefreshSubscriptionStatus() async {
        do {
            try await store?.updatePurchases()
        } catch {
            iapLog("❌ Failed to update purchases: \(error)")
        }

        await IAPHelper.shared.refreshFromStoreKit()

        self.objectWillChange.send()
    }

    // MARK: - Set Store Context
    public func setStoreContext(_ storeContext: StoreContext) {
        self.store = storeContext
        subscriptionHandler = IAPSubscriptionHandler(store: store)
        Task { await checkAndUpdateSubscriptionStatus() }
    }

    // MARK: - Set Selected Product
    public func setSelectedProduct(_ product: Product?) {
        self.selectedProduct = product
    }

    // MARK: - Check Purchase Status
    public func isPurchased(_ productId: String) -> Bool {
        store?.isProductPurchased(id: productId) ?? false
    }

    // MARK: - Check Subscription Status
    public func isSubscriptionActive(_ productId: String) -> Bool {
        store?.isProductPurchased(id: productId) ?? false
    }

    // MARK: - Check Subscription Status (Async with proper transaction check)
    public func isSubscriptionActiveAsync(_ productId: String) async -> Bool {
        do {
            if let transaction = try await store?.getValidTransaction(for: productId) {
                let isActive = transaction.isValid
                if isActive && transaction.revocationDate == nil {
                    if let expirationDate = transaction.expirationDate {
                        return expirationDate > Date()
                    } else {
                        return true // Lifetime / non-expiring
                    }
                }
                return false
            }
            return false
        } catch {
            iapLog("❌ Error checking subscription status: \(error)")
            return false
        }
    }

    // MARK: - Get Subscription Status Text
    public func getSubscriptionStatusText(_ productId: String) -> String {
        (store?.isProductPurchased(id: productId) == true) ? "Active" : ""
    }

    // MARK: - Non-Main Actor Wrappers
    public nonisolated func isPurchasedAsync(_ productId: String) async -> Bool {
        await MainActor.run { self.isPurchased(productId) }
    }

    // MARK: - Can Purchase Product
    public func canPurchaseProduct(_ product: Product) -> Bool {
        if isLoading { return false }

        if IAPConfiguration.shared.subscriptionProductIds.contains(product.id) {
            let hasActiveSubscription = IAPConfiguration.shared.subscriptionProductIds.contains { productId in
                isSubscriptionActive(productId)
            }

            if hasActiveSubscription {
                let currentSubscription = getCurrentActiveSubscription()
                if let current = currentSubscription {
                    return canUpgradeOrSwitch(from: current, to: product)
                }
                return false
            }
        }

        if isSubscriptionActive(product.id) { return false }

        return true
    }

    // MARK: - Get Current Active Subscription
    private func getCurrentActiveSubscription() -> Product? {
        for productId in IAPConfiguration.shared.subscriptionProductIds {
            if isSubscriptionActive(productId) {
                return products.first { $0.id == productId }
            }
        }
        return nil
    }

    // MARK: - Check if can upgrade or switch subscription
    private func canUpgradeOrSwitch(from current: Product, to new: Product) -> Bool {
        if current.id == new.id { return false }

        guard let currentPeriod = current.subscription?.subscriptionPeriod,
              let newPeriod = new.subscription?.subscriptionPeriod else {
            return false
        }

        let currentDays = getDaysFromPeriod(currentPeriod)
        let newDays = getDaysFromPeriod(newPeriod)

        // Allow if new subscription is longer (upgrade) or same length (switch).
        return newDays >= currentDays
    }

    // MARK: - Convert subscription period to days
    private func getDaysFromPeriod(_ period: Product.SubscriptionPeriod) -> Int {
        switch period.unit {
        case .day:   return period.value
        case .week:  return period.value * 7
        case .month: return period.value * 30
        case .year:  return period.value * 365
        @unknown default: return 0
        }
    }

    // MARK: - Restore Purchases
    public func restorePurchases() {
        ads.setExcludeScreen(true)
        isLoading = true
        errorMessage = nil
        restoreSuccessful = false

        Task {
            do {
                // Dùng số transaction TRẢ VỀ từ restore — `purchasedProductIds`
                // được republish qua `DispatchQueue.main.async` nên đọc ngay
                // sau await vẫn là giá trị cũ. Trên máy cài mới (persisted
                // rỗng) điều đó từng làm restore thành công nhưng báo
                // "no purchases found" và bỏ qua bước refresh cache.
                var restoredCount = 0
                if let store {
                    restoredCount = try await store.restorePurchases()
                }
                self.isLoading = false

                if restoredCount > 0 {
                    await self.checkAndUpdateSubscriptionStatus()

                    if IAPHelper.shared.isPremium {
                        ads.setShouldShowAds(false)
                        ads.setExcludeScreen(false)
                        self.restoreSuccessful = true
                        self.showingPurchaseAlert = true
                    } else {
                        ads.setExcludeScreen(false)
                        self.errorMessage = "restore_completed".localized
                        self.showingPurchaseAlert = true
                    }
                } else {
                    ads.setExcludeScreen(false)
                    self.errorMessage = "no_purchases_found_to_restore".localized
                    self.showingPurchaseAlert = true
                }
            } catch {
                ads.setExcludeScreen(false)
                self.isLoading = false
                self.errorMessage = IAPErrorHandler.getRestoreErrorMessage(error)
                self.showingPurchaseAlert = true
                iapLog("❌ Restore failed: \(error)")
            }
        }
    }

    // MARK: - Clear Error
    public func clearError() {
        errorMessage = nil
        showingPurchaseAlert = false
    }

    // MARK: - Clear Selected Product
    public func clearSelectedProduct() {
        setSelectedProduct(nil)
    }

    // MARK: - Reset Restore Flag
    public func resetRestoreFlag() {
        restoreSuccessful = false
    }

    // MARK: - Refresh Purchase Status
    public func refreshPurchaseStatus() {
        Task {
            do {
                try await store?.updatePurchases()
                await checkAndUpdateSubscriptionStatus()
                objectWillChange.send()
            } catch {
                iapLog("❌ Failed to refresh purchase status: \(error)")
            }
        }
    }

    // MARK: - Check Can Make Payments
    public func canMakePayments() -> Bool {
        AppStore.canMakePayments
    }

    // MARK: - Get Products
    public var products: [Product] {
        store?.products ?? []
    }

    // MARK: - Purchase Product
    public func purchaseProduct(_ product: Product) {
        ads.setExcludeScreen(true)
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let (result, _) = try await store?.purchase(product) ?? (.userCancelled, nil)

                self.isLoading = false

                switch result {
                case .success(let verificationResult):
                    switch verificationResult {
                    case .verified(let transaction):
                        // Sandbox environments frequently return an already-expired
                        // transaction once the account has hit its renewal test limit.
                        if let expirationDate = transaction.expirationDate, expirationDate <= Date() {
                            ads.setExcludeScreen(false)
                            self.errorMessage = "iap_sandbox_renewal_limit_reached".localized
                            self.showingPurchaseAlert = true
                            return
                        }

                        iapLog("✅ Purchase success: \(transaction.productID)")

                        self.setSelectedProduct(nil)
                        ads.setShouldShowAds(false)
                        // Cache `iap_is_premium` phải ĐÚNG trước khi bật
                        // `showingPurchaseAlert` — host app dùng cờ này làm
                        // tín hiệu dismiss paywall, và ngay sau dismiss có thể
                        // show interstitial được gate bằng cache đó. Đảo thứ
                        // tự là có cửa sổ vài chục ms user vừa trả tiền xong
                        // vẫn ăn ad. (`refreshFromCache()` cũ bị xoá vì nó
                        // no-op: đọc UserDefaults rồi ghi lại y nguyên.)
                        await self.checkAndUpdateSubscriptionStatus()
                        ads.setExcludeScreen(false)
                        self.errorMessage = nil
                        self.showingPurchaseAlert = true

                        // Schedule free-trial expiration notification if applicable.
                        if let expirationDate = transaction.expirationDate {
                            let daysUntilExpiration = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
                            if daysUntilExpiration <= 3 && daysUntilExpiration > 0 {
                                trialNotifications.scheduleFreeTrialExpirationNotification(expirationDate: expirationDate)
                            }
                        }

                    case .unverified(_, let error):
                        ads.setExcludeScreen(false)
                        self.errorMessage = "Purchase verification failed: \(error.localizedDescription)"
                        self.showingPurchaseAlert = true
                    }

                case .pending:
                    ads.setExcludeScreen(false)
                    self.errorMessage = "purchase_pending_approval".localized
                    self.showingPurchaseAlert = true
                case .userCancelled:
                    ads.setExcludeScreen(false)
                    // Silent — user chose to cancel; no alert needed by default.
                    self.showingPurchaseAlert = false
                @unknown default:
                    ads.setExcludeScreen(false)
                    self.errorMessage = "purchase_failed_unknown".localized
                    self.showingPurchaseAlert = true
                }
            } catch {
                ads.setExcludeScreen(false)
                self.isLoading = false
                self.errorMessage = IAPErrorHandler.getPurchaseErrorMessage(error)
                self.showingPurchaseAlert = true
            }
        }
    }

    // MARK: - Purchase Product (for backward compatibility)
    public func purchase(_ product: Product) {
        purchaseProduct(product)
    }

    // MARK: - Subscription Status Refresh

    /// Validates against StoreKit 2 and refreshes the UserDefaults cache.
    /// Also triggers a UI update for any observing views.
    public func checkAndUpdateSubscriptionStatus() async {
        await IAPHelper.shared.refreshFromStoreKit()
        self.objectWillChange.send()
    }

    // MARK: - Check if Subscription is Expired
    public func isSubscriptionExpired(for productId: String) async -> Bool {
        let (isActive, _) = await subscriptionHandler?.checkSubscriptionExpirationDate(for: productId) ?? (false, nil)
        return !isActive
    }

    // MARK: - Check Subscription Status (Enhanced)
    public func checkSubscriptionStatus(for productId: String) async -> SubscriptionStatusInfo {
        await subscriptionHandler?.checkSubscriptionStatus(for: productId) ?? SubscriptionStatusInfo(
            productId: productId,
            status: .error,
            isActive: false,
            expirationDate: nil,
            revocationDate: nil,
            message: "Error checking subscription status"
        )
    }
}
