//
//  StoreContext.swift
//  SwiftIAP
//
//  Native StoreKit 2 wrapper. Keeps the list of available products and the
//  user's purchased product IDs in sync with the App Store, and listens for
//  background transaction updates (renewals, promoted purchases, refunds).
//

import Foundation
import StoreKit
import Combine

// MARK: - Type aliases

public typealias ProductID = String
public typealias ProductFetchID = String

// MARK: - InAppProduct

/// A lightweight protocol for enums that describe the app's in-app products.
public protocol InAppProduct: CaseIterable, Identifiable where ID == ProductID {
    var id: ProductID { get }
}

public extension Collection where Element: InAppProduct {
    /// Returns the products that are currently available in the given context.
    func available(in context: StoreContext) -> [Self.Element] {
        let ids = Set(context.productIds)
        return self.filter { ids.contains($0.id) }
    }

    /// Returns the products that have been purchased in the given context.
    func purchased(in context: StoreContext) -> [Self.Element] {
        let ids = Set(context.purchasedProductIds)
        return self.filter { ids.contains($0.id) }
    }
}

// MARK: - ValidatableTransaction

/// Any type that can be checked for revocation / expiration.
public protocol ValidatableTransaction {
    var expirationDate: Date? { get }
    var revocationDate: Date? { get }
}

extension Transaction: ValidatableTransaction {}

public extension ValidatableTransaction {
    /// `true` if the transaction has not been revoked and has not expired.
    var isValid: Bool {
        if revocationDate != nil { return false }
        guard let expirationDate else { return true }
        return expirationDate > Date()
    }
}

// MARK: - StoreServiceError

public enum StoreServiceError: Error, LocalizedError {
    case invalidTransaction(Transaction, Error)
    case productNotFound(ProductID)

    public var errorDescription: String? {
        switch self {
        case .invalidTransaction(_, let error):
            return "Invalid transaction: \(error.localizedDescription)"
        case .productNotFound(let id):
            return "Product not found: \(id)"
        }
    }
}

// MARK: - StoreContext

/// Observable wrapper around StoreKit 2 that keeps the list of available
/// products and purchased product IDs in sync with the App Store.
public final class StoreContext: ObservableObject, @unchecked Sendable {

    // MARK: Persistence keys (namespaced via IAPConfiguration.persistenceKeyPrefix)
    private var productIdsKey: String {
        "\(IAPConfiguration.shared.persistenceKeyPrefix).productIds"
    }
    private var purchasedProductIdsKey: String {
        "\(IAPConfiguration.shared.persistenceKeyPrefix).purchasedProductIds"
    }

    // MARK: Published state

    /// All product IDs the app is aware of.
    @Published public internal(set) var productIds: [ProductID] = [] {
        didSet { persist(productIds, forKey: productIdsKey) }
    }

    /// Products fetched from the App Store, in the order declared by `productIds`.
    @Published public var products: [Product] = []

    /// IDs of products that the user currently owns / has an active subscription for.
    @Published public internal(set) var purchasedProductIds: [ProductID] = [] {
        didSet { persist(purchasedProductIds, forKey: purchasedProductIdsKey) }
    }

    /// Flag used by the UI to show a purchase popup. Left for compatibility.
    @Published public var isShowingPurchasePopup: Bool = false

    // MARK: Private state

    private var purchaseTransactions: [Transaction] = [] {
        didSet {
            let ids = purchaseTransactions.map { $0.productID }
            DispatchQueue.main.async { [weak self] in
                self?.purchasedProductIds = ids
            }
        }
    }

    private var transactionUpdateTask: Task<Void, Never>?

    // MARK: Init

    public convenience init<P: InAppProduct>(products: [P]) {
        self.init(productIds: products.map { $0.id })
    }

    public init(productIds: [ProductID] = []) {
        // Restore persisted state first so the UI has something to show immediately.
        let persistedIds: [ProductID] = Self.loadPersisted(forKey: productIdsKey) ?? []
        self.productIds = productIds.isEmpty ? persistedIds : productIds
        self.purchasedProductIds = Self.loadPersisted(forKey: purchasedProductIdsKey) ?? []

        // Start listening for transaction updates (renewals, promoted purchases, …).
        self.transactionUpdateTask = listenForTransactionUpdates()

        // Kick off initial sync in the background.
        Task { [weak self] in
            try? await self?.syncStoreData()
        }
    }

    deinit {
        transactionUpdateTask?.cancel()
    }

    // MARK: - Public API

    /// Fetches the latest product metadata and the user's valid transactions.
    @MainActor
    public func syncStoreData() async throws {
        let fetched = try await Product.products(for: productIds)
        if !fetched.isEmpty {
            updateProducts(fetched)
        }
        try await updatePurchases()
    }

    /// Re-reads all valid transactions from StoreKit and updates `purchasedProductIds`.
    ///
    /// - Returns: number of valid transactions found. Callers that need to
    ///   branch on the result MUST use this return value — `purchasedProductIds`
    ///   is republished via `DispatchQueue.main.async` (see
    ///   `purchaseTransactions.didSet`) and is therefore still stale when this
    ///   method returns.
    @MainActor
    @discardableResult
    public func updatePurchases() async throws -> Int {
        var transactions: [Transaction] = []
        for id in productIds {
            if let tx = try await getValidTransaction(for: id) {
                transactions.append(tx)
            }
        }
        purchaseTransactions = transactions
        return transactions.count
    }

    /// Asks the App Store to restore previous purchases, then refreshes state.
    ///
    /// - Returns: number of valid transactions found after the sync (see
    ///   `updatePurchases()` for why the return value, not
    ///   `purchasedProductIds`, must be used for decisions).
    @MainActor
    @discardableResult
    public func restorePurchases() async throws -> Int {
        try await AppStore.sync()
        return try await updatePurchases()
    }

    /// Replaces the current product list, keeping the order defined by `productIds`.
    @MainActor
    public func updateProducts(_ products: [Product]) {
        let order = productIds
        self.products = products
            .filter { order.contains($0.id) }
            .sorted { lhs, rhs in
                let l = order.firstIndex(of: lhs.id) ?? Int.max
                let r = order.firstIndex(of: rhs.id) ?? Int.max
                return l < r
            }
    }

    // MARK: Queries

    public var hasNotPurchased: Bool { purchasedProductIds.isEmpty }

    public func isProductPurchased(id: ProductID) -> Bool {
        purchasedProductIds.contains(id)
    }

    public func isProductPurchased(_ product: Product) -> Bool {
        isProductPurchased(id: product.id)
    }

    public func product(withId id: ProductFetchID) -> Product? {
        products.first { $0.id == id }
    }

    /// Returns the latest verified, still-valid transaction for a product, if any.
    /// Expired / revoked transactions are filtered out — use this for
    /// **entitlement** checks ("does the user currently own premium").
    public func getValidTransaction(for productId: ProductID) async throws -> Transaction? {
        guard let transaction = try await getLatestTransaction(for: productId) else { return nil }
        return transaction.isValid ? transaction : nil
    }

    /// Returns the latest verified transaction for a product **regardless of
    /// validity** (expired and revoked transactions are included). Use this to
    /// inspect subscription *state* (expiration date, revocation date); use
    /// `getValidTransaction` when you only care about active entitlement.
    public func getLatestTransaction(for productId: ProductID) async throws -> Transaction? {
        guard let latest = await Transaction.latest(for: productId) else { return nil }
        return try Self.verify(latest)
    }

    // MARK: Purchase

    /// Initiates a purchase. On success, finishes the transaction and updates state.
    @MainActor
    @discardableResult
    public func purchase(_ product: Product) async throws -> (Product.PurchaseResult, Transaction?) {
        let result = try await product.purchase()
        var finishedTransaction: Transaction?

        switch result {
        case .success(let verification):
            let transaction = try Self.verify(verification)
            await transaction.finish()
            finishedTransaction = transaction
            updatePurchaseTransactions(with: transaction)
        case .pending, .userCancelled:
            break
        @unknown default:
            break
        }

        return (result, finishedTransaction)
    }

    // MARK: - Private helpers

    @MainActor
    private func updatePurchaseTransactions(with transaction: Transaction) {
        var transactions = purchaseTransactions.filter { $0.productID != transaction.productID }
        transactions.append(transaction)
        purchaseTransactions = transactions
    }

    /// Background listener for `Transaction.updates`. Runs for the lifetime of `self`.
    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try Self.verify(result)
                    await transaction.finish()
                    await self.updatePurchaseTransactions(with: transaction)
                    // Keep the fast `isPremium` cache in sync immediately —
                    // without this, an Ask-to-Buy approval or renewal that
                    // arrives while the app is foregrounded unlocks the UI
                    // (via `purchasedProductIds`) but ads/gates keep reading
                    // a stale `false` until the next foreground refresh.
                    await IAPHelper.shared.refreshFromStoreKit()
                } catch {
                    iapLog("🚨 Transaction listener error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Unwraps a `VerificationResult`, throwing on unverified transactions.
    private static func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(let value, let error):
            if let tx = value as? Transaction {
                throw StoreServiceError.invalidTransaction(tx, error)
            }
            throw error
        }
    }

    // MARK: Persistence

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadPersisted<T: Decodable>(forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
