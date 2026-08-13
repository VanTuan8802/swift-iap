//
//  SwiftIAP.swift
//  SwiftIAP
//
//  Umbrella conveniences: a one-call bootstrap that wires `StoreContext`,
//  `IAPHelper`, and `IAPManager` together in the correct order (as described
//  in the integration guide).
//

import Foundation

public enum SwiftIAP {

    /// Creates and wires the full IAP stack. Call once at app launch **after**
    /// `IAPConfiguration.shared.configure(...)`.
    ///
    /// Order matters: `setStoreContext` must run before `setup()`.
    ///
    /// - Returns: the `StoreContext` to inject as an `@EnvironmentObject`.
    @MainActor
    @discardableResult
    public static func bootstrap(productIds: [String]? = nil) -> StoreContext {
        let ids = productIds
            ?? (IAPConfiguration.shared.premiumProductIds.isEmpty
                ? []
                : IAPConfiguration.shared.premiumProductIds)

        let store = StoreContext(productIds: ids)

        IAPHelper.shared.setStoreContext(store)
        IAPManager.shared.setStoreContext(store)
        IAPManager.shared.setup()

        Task { await IAPHelper.shared.refreshFromStoreKit() }

        return store
    }
}
