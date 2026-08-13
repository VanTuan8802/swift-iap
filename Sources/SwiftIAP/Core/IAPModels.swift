//
//  IAPModels.swift
//  SwiftIAP
//

import Foundation

// MARK: - Subscription Status Type
public enum SubscriptionStatusType: Sendable {
    case active
    case expiringSoon
    case expired
    case cancelled
    case revoked
    case notPurchased
    case error

    public var description: String {
        switch self {
        case .active: return "Active"
        case .expiringSoon: return "Expiring Soon"
        case .expired: return "Expired"
        case .cancelled: return "Cancelled"
        case .revoked: return "Revoked"
        case .notPurchased: return "Not Purchased"
        case .error: return "Error"
        }
    }
}

// MARK: - Subscription Status Info
public struct SubscriptionStatusInfo: Sendable {
    public let productId: String
    public let status: SubscriptionStatusType
    public let isActive: Bool
    public let expirationDate: Date?
    public let revocationDate: Date?
    public let message: String

    public init(
        productId: String,
        status: SubscriptionStatusType,
        isActive: Bool,
        expirationDate: Date?,
        revocationDate: Date?,
        message: String
    ) {
        self.productId = productId
        self.status = status
        self.isActive = isActive
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.message = message
    }

    public var daysUntilExpiration: Int? {
        guard let expirationDate = expirationDate else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.day], from: now, to: expirationDate)
        return components.day
    }

    public var isRevoked: Bool { revocationDate != nil }
    public var isCancelled: Bool { status == .cancelled }
    public var isExpired: Bool { status == .expired }
}

// MARK: - UserDefaults Keys
public enum IAPUserDefaultsKeys {
    public static let isPremium = "iap_is_premium"
    public static let hasRestoredOnFirstLaunch = "iap_has_restored_on_first_launch"
    public static let accountIdentifier = "iap_account_identifier"
    public static let networkErrorCount = "iap_network_error_count"
    public static let lastNetworkError = "iap_last_network_error"
    public static let hasShownIAPView = "iap_has_shown_iap_view"
    public static let lastIAPViewShowDate = "iap_last_iap_view_show_date"
    public static let hasEnteredHomeView = "iap_has_entered_home_view"
}
