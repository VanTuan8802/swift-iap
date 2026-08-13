//
//  IAPSubscriptionHandler.swift
//  SwiftIAP
//
//  Detailed subscription-state analysis: expiring soon, expired, user-cancelled
//  (grace period), and Apple-revoked-after-refund. Keeps the premium cache in
//  sync with the true StoreKit state.
//

import Foundation
import StoreKit

@MainActor
public final class IAPSubscriptionHandler {
    private weak var store: StoreContext?

    public init(store: StoreContext?) {
        self.store = store
    }

    // MARK: - Check Subscription Expiration Date
    public func checkSubscriptionExpirationDate(for productId: String) async -> (isActive: Bool, expirationDate: Date?) {
        do {
            // Use the *unfiltered* latest transaction so we can actually observe
            // expired / revoked states (getValidTransaction would drop them).
            if let transaction = try await store?.getLatestTransaction(for: productId) {
                let expirationDate = transaction.expirationDate
                let isActive = transaction.isValid
                let revocationDate = transaction.revocationDate

                iapLog("📅 Subscription \(productId):")
                iapLog("   - Expiration Date: \(expirationDate?.description ?? "No expiration")")
                iapLog("   - Is Active: \(isActive)")
                iapLog("   - Revocation Date: \(revocationDate?.description ?? "Not revoked")")

                await checkCancellationScenarios(productId: productId, isActive: isActive, expirationDate: expirationDate, revocationDate: revocationDate)

                return (isActive: isActive, expirationDate: expirationDate)
            } else {
                iapLog("📅 Subscription \(productId): No valid transaction found")
                return (isActive: false, expirationDate: nil)
            }
        } catch {
            iapLog("❌ Error checking subscription expiration: \(error)")
            return (isActive: false, expirationDate: nil)
        }
    }

    // MARK: - Check Cancellation Scenarios
    private func checkCancellationScenarios(productId: String, isActive: Bool, expirationDate: Date?, revocationDate: Date?) async {
        // Check if revoked FIRST (Apple revoke after refund) - Highest priority
        if revocationDate != nil {
            iapLog("🚨 Subscription revoked by Apple (after refund): \(productId)")
            await handleRevokedAfterRefund(productId: productId, revocationDate: revocationDate)
            return
        }

        // Check if expired
        if let expirationDate = expirationDate, expirationDate < Date() {
            iapLog("❌ Subscription expired: \(productId)")
            await handleExpiredSubscription(productId: productId, expirationDate: expirationDate)
            return
        }

        // Check if cancelled (user cancel) - grace period
        if !isActive, let expirationDate = expirationDate, expirationDate > Date() {
            iapLog("🚫 User cancelled subscription (with possible refund request): \(productId)")
            await handleCancelledWithRefundRequest(productId: productId, expirationDate: expirationDate)
            return
        }

        // Check if auto-renewal disabled but still active
        if isActive, let expirationDate = expirationDate {
            let daysUntilExpiration = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
            if daysUntilExpiration <= 7 {
                iapLog("⏰ Subscription expiring soon (auto-renewal may be disabled): \(productId)")
                await handleExpiringSoonSubscription(productId: productId, expirationDate: expirationDate, daysUntilExpiration: daysUntilExpiration)
            }
        }
    }

    // MARK: - Handle Revoked After Refund
    private func handleRevokedAfterRefund(productId: String, revocationDate: Date?) async {
        await updatePremiumStatusForRevokedSubscription()
        logSubscriptionEvent("subscription_revoked_after_refund", productId: productId, additionalData: [
            "revocation_date": revocationDate?.description ?? "unknown",
            "reason": "apple_revocation_after_refund"
        ])
    }

    // MARK: - Handle Expired Subscription
    private func handleExpiredSubscription(productId: String, expirationDate: Date) async {
        await updatePremiumStatusForExpiredSubscription()
        logSubscriptionEvent("subscription_expired", productId: productId, additionalData: [
            "expiration_date": expirationDate.description
        ])
    }

    // MARK: - Handle Cancelled with Refund Request
    private func handleCancelledWithRefundRequest(productId: String, expirationDate: Date) async {
        let daysUntilExpiration = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
        await updatePremiumStatusForCancelledSubscription(daysUntilExpiration: daysUntilExpiration)
        logSubscriptionEvent("subscription_cancelled_with_refund_request", productId: productId, additionalData: [
            "expiration_date": expirationDate.description,
            "days_until_expiration": daysUntilExpiration,
            "reason": "user_cancellation_with_refund_request"
        ])
    }

    // MARK: - Handle Expiring Soon Subscription
    private func handleExpiringSoonSubscription(productId: String, expirationDate: Date, daysUntilExpiration: Int) async {
        logSubscriptionEvent("subscription_expiring_soon", productId: productId, additionalData: [
            "expiration_date": expirationDate.description,
            "days_until_expiration": daysUntilExpiration
        ])
    }

    // MARK: - Update Premium Status Based on Expiration
    public func updatePremiumStatusBasedOnExpiration() async {
        iapLog("🔄 Updating premium status based on subscription expiration...")

        var hasActivePremium = false

        for productId in IAPConfiguration.shared.premiumProductIds {
            let (isActive, expirationDate) = await checkSubscriptionExpirationDate(for: productId)

            if isActive {
                hasActivePremium = true
                if let expirationDate = expirationDate {
                    await checkAndScheduleFreeTrialNotification(expirationDate: expirationDate)
                }
                break
            }
        }

        UserDefaults.standard.set(hasActivePremium, forKey: IAPUserDefaultsKeys.isPremium)
        iapLog("📊 Premium Status Updated: isPremium=\(hasActivePremium)")
        IAPHelper.shared.refreshFromCache()
    }

    // MARK: - Check and Schedule Free Trial Notification
    private func checkAndScheduleFreeTrialNotification(expirationDate: Date) async {
        let daysUntilExpiration = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0

        if daysUntilExpiration <= 3 && daysUntilExpiration > 0 {
            IAPConfiguration.shared.trialNotifications.scheduleFreeTrialExpirationNotification(expirationDate: expirationDate)
        } else if daysUntilExpiration <= 0 {
            IAPConfiguration.shared.trialNotifications.removeFreeTrialNotification()
        }
    }

    // MARK: - Premium status mutators
    private func updatePremiumStatusForRevokedSubscription() async {
        UserDefaults.standard.set(false, forKey: IAPUserDefaultsKeys.isPremium)
        IAPHelper.shared.refreshFromCache()
    }

    private func updatePremiumStatusForExpiredSubscription() async {
        UserDefaults.standard.set(false, forKey: IAPUserDefaultsKeys.isPremium)
        IAPHelper.shared.refreshFromCache()
    }

    private func updatePremiumStatusForCancelledSubscription(daysUntilExpiration: Int) async {
        if daysUntilExpiration > 0 {
            // Still premium until expiration (grace period)
            UserDefaults.standard.set(true, forKey: IAPUserDefaultsKeys.isPremium)
        } else {
            UserDefaults.standard.set(false, forKey: IAPUserDefaultsKeys.isPremium)
        }
        IAPHelper.shared.refreshFromCache()
    }

    // MARK: - Check Subscription Status (Enhanced)
    public func checkSubscriptionStatus(for productId: String) async -> SubscriptionStatusInfo {
        let (isActive, expirationDate) = await checkSubscriptionExpirationDate(for: productId)

        var revocationDate: Date? = nil
        do {
            if let transaction = try await store?.getLatestTransaction(for: productId) {
                revocationDate = transaction.revocationDate
            }
        } catch {
            iapLog("❌ Error getting transaction for revocation check: \(error)")
        }

        var status: SubscriptionStatusType = .notPurchased
        var message = ""

        if revocationDate != nil {
            status = .revoked
            message = String(format: "subscription_revoked_by_apple".localized, IAPErrorHandler.formatDate(revocationDate))
        } else if isActive {
            if let expirationDate = expirationDate {
                let daysUntilExpiration = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
                if daysUntilExpiration <= 7 {
                    status = .expiringSoon
                    message = String(format: "subscription_expires_in_days".localized, daysUntilExpiration)
                } else {
                    status = .active
                    message = "subscription_is_active".localized
                }
            } else {
                status = .active
                message = "subscription_is_active_no_expiration".localized
            }
        } else {
            if let expirationDate = expirationDate {
                if expirationDate < Date() {
                    status = .expired
                    message = String(format: "subscription_expired_on".localized, IAPErrorHandler.formatDate(expirationDate))
                } else {
                    status = .cancelled
                    let daysUntilExpiration = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
                    message = String(format: "subscription_cancelled_but_active".localized, IAPErrorHandler.formatDate(expirationDate), daysUntilExpiration)
                }
            } else {
                status = .notPurchased
                message = "no_subscription_found".localized
            }
        }

        return SubscriptionStatusInfo(
            productId: productId,
            status: status,
            isActive: isActive,
            expirationDate: expirationDate,
            revocationDate: revocationDate,
            message: message
        )
    }

    // MARK: - Log Subscription Event
    private func logSubscriptionEvent(_ event: String, productId: String, additionalData: [String: Any] = [:]) {
        guard IAPConfiguration.shared.isLoggingEnabled else { return }
        var logData: [String: Any] = [
            "event": event,
            "product_id": productId,
            "timestamp": Date().description
        ]
        for (key, value) in additionalData { logData[key] = value }
        iapLog("📊 Subscription Event: \(event) for \(productId) - \(logData)")
    }
}
