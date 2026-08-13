import XCTest
@testable import SwiftIAP

final class SwiftIAPTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Isolate UserDefaults keys used by the package under test.
        UserDefaults.standard.removeObject(forKey: IAPUserDefaultsKeys.isPremium)
        UserDefaults.standard.removeObject(forKey: "free_measure_count")
        UserDefaults.standard.removeObject(forKey: "last_free_measure_date")
    }

    // MARK: - Configuration

    func testConfigureSetsCatalog() {
        IAPConfiguration.shared.configure(
            premiumProductIds: ["com.demo.weekly", "com.demo.yearly"]
        )
        XCTAssertEqual(IAPConfiguration.shared.premiumProductIds.count, 2)
        // subscriptionProductIds defaults to premium list.
        XCTAssertEqual(IAPConfiguration.shared.subscriptionProductIds,
                       IAPConfiguration.shared.premiumProductIds)
    }

    func testConfigureFromEnum() {
        enum Demo: String, InAppProduct, CaseIterable {
            case weekly = "com.demo.weekly"
            case yearly = "com.demo.yearly"
            var id: String { rawValue }
        }
        IAPConfiguration.shared.configure(products: Demo.self)
        XCTAssertEqual(Set(IAPConfiguration.shared.premiumProductIds),
                       ["com.demo.weekly", "com.demo.yearly"])
    }

    // MARK: - Access rules

    func testHasPremiumAccessWhenIAPDisabled() {
        IAPConfiguration.shared.configure(
            premiumProductIds: ["x"],
            remoteConfig: DefaultIAPRemoteConfig(enableIAP: false)
        )
        XCTAssertFalse(IAPHelper.shared.isPremium)
        XCTAssertTrue(IAPHelper.shared.hasPremiumAccess) // gate open because IAP off
        XCTAssertFalse(IAPHelper.shared.shouldGatePremium)
    }

    func testShouldGateWhenNotPremiumAndIAPEnabled() {
        IAPConfiguration.shared.configure(
            premiumProductIds: ["x"],
            remoteConfig: DefaultIAPRemoteConfig(enableIAP: true)
        )
        XCTAssertTrue(IAPHelper.shared.shouldGatePremium)
    }

    // MARK: - Transaction validity

    func testValidatableTransactionExpiry() {
        struct T: ValidatableTransaction {
            var expirationDate: Date?
            var revocationDate: Date?
        }
        XCTAssertTrue(T(expirationDate: nil, revocationDate: nil).isValid)
        XCTAssertTrue(T(expirationDate: Date().addingTimeInterval(60), revocationDate: nil).isValid)
        XCTAssertFalse(T(expirationDate: Date().addingTimeInterval(-60), revocationDate: nil).isValid)
        XCTAssertFalse(T(expirationDate: Date().addingTimeInterval(60), revocationDate: Date()).isValid)
    }

    // MARK: - Free tier

    func testFreeMeasureLimit() {
        IAPConfiguration.shared.configure(
            premiumProductIds: ["x"],
            remoteConfig: DefaultIAPRemoteConfig(enableIAP: true, freeMeasureLimit: 2, freeMeasureIntervalHours: 24)
        )
        FreeMeasureManager.shared.reset()

        XCTAssertEqual(FreeMeasureManager.shared.getRemainingFreeMeasures(), 2)
        XCTAssertTrue(FreeMeasureManager.shared.canMeasureFree())

        FreeMeasureManager.shared.recordFreeMeasure()
        XCTAssertEqual(FreeMeasureManager.shared.getRemainingFreeMeasures(), 1)

        FreeMeasureManager.shared.recordFreeMeasure()
        XCTAssertEqual(FreeMeasureManager.shared.getRemainingFreeMeasures(), 0)
        XCTAssertFalse(FreeMeasureManager.shared.canMeasureFree())
    }

    // MARK: - Entitlement vs. state separation

    func testValidVsLatestTransactionSemantics() {
        // Entitlement (isValid) must reject an expired transaction, while the
        // "state" view keeps it so expiry can be reported. This models the two
        // StoreContext accessors: getValidTransaction filters, getLatestTransaction does not.
        struct T: ValidatableTransaction {
            var expirationDate: Date?
            var revocationDate: Date?
        }
        let expired = T(expirationDate: Date().addingTimeInterval(-3600), revocationDate: nil)
        let revoked = T(expirationDate: Date().addingTimeInterval(3600), revocationDate: Date())

        // "valid" accessor would drop both:
        XCTAssertFalse(expired.isValid)
        XCTAssertFalse(revoked.isValid)
        // but the raw dates remain observable for status reporting:
        XCTAssertNotNil(expired.expirationDate)
        XCTAssertNotNil(revoked.revocationDate)
    }

    // MARK: - Localization hook

    func testCustomLocalizer() {
        IAPConfiguration.shared.configure(
            premiumProductIds: ["x"],
            localize: { key in key == "unknown" ? "N/A" : key }
        )
        XCTAssertEqual(IAPErrorHandler.formatDate(nil), "N/A")
    }
}
