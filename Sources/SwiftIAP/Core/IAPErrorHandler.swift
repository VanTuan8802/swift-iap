//
//  IAPErrorHandler.swift
//  SwiftIAP
//
//  Maps StoreKit errors to localized, user-facing messages. All strings are
//  resolved through `IAPConfiguration.localize`, so a host app supplies the
//  translations (or gets the key back verbatim as a fallback).
//

import Foundation

public enum IAPErrorHandler {

    // MARK: - Get Restore Error Message
    public static func getRestoreErrorMessage(_ error: Error) -> String {
        let errorDescription = error.localizedDescription.lowercased()

        if errorDescription.contains("network") || errorDescription.contains("connection") {
            return "network_connection_required".localized
        } else if errorDescription.contains("apple id") || errorDescription.contains("sign in") {
            return "sign_in_apple_id_restore".localized
        } else if errorDescription.contains("store") || errorDescription.contains("unavailable") {
            return "app_store_unavailable".localized
        } else if errorDescription.contains("configuration") || errorDescription.contains("product") {
            return "store_configuration_error".localized
        } else if errorDescription.contains("verification") || errorDescription.contains("receipt") {
            return "purchase_verification_failed".localized
        } else {
            return String(format: "restore_failed".localized, error.localizedDescription)
        }
    }

    // MARK: - Get Purchase Error Message
    public static func getPurchaseErrorMessage(_ error: Error) -> String {
        let errorDescription = error.localizedDescription.lowercased()

        if errorDescription.contains("payment") || errorDescription.contains("billing") {
            return "payment_issue".localized
        } else if errorDescription.contains("network") || errorDescription.contains("connection") {
            return "network_connection_required".localized
        } else if errorDescription.contains("store") || errorDescription.contains("unavailable") {
            return "app_store_unavailable".localized
        } else {
            return String(format: "purchase_failed".localized, error.localizedDescription)
        }
    }

    // MARK: - Format Date Helper
    public static func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "unknown".localized }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
