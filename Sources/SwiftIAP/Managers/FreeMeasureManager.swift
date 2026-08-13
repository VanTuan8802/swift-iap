//
//  FreeMeasureManager.swift
//  SwiftIAP
//
//  Optional free-tier gate: limits how many times a free user can use a
//  metered feature within a rolling interval. Premium users are unlimited.
//  Limits come from `IAPConfiguration.remoteConfig`.
//

import Foundation

public final class FreeMeasureManager {
    public static let shared = FreeMeasureManager()

    private let freeMeasureCountKey = "free_measure_count"
    private let lastFreeMeasureDateKey = "last_free_measure_date"

    private init() {}

    private var config: IAPRemoteConfigProviding { IAPConfiguration.shared.remoteConfig }

    /// Whether the user may perform another free use right now.
    /// Premium users always return `true`.
    public func canMeasureFree() -> Bool {
        if IAPHelper.shared.isPremium { return true }

        let limit = config.getFreeMeasureLimitPerInterval()
        let intervalHours = config.getFreeMeasureTimeInterval()

        let count = UserDefaults.standard.integer(forKey: freeMeasureCountKey)
        let lastDate = UserDefaults.standard.object(forKey: lastFreeMeasureDateKey) as? Date

        // No prior use → allowed.
        guard let lastDate = lastDate else { return true }

        let hoursSinceLastMeasure = Date().timeIntervalSince(lastDate) / 3600.0

        if hoursSinceLastMeasure >= Double(intervalHours) {
            // Interval elapsed → reset counter and allow.
            UserDefaults.standard.set(0, forKey: freeMeasureCountKey)
            return true
        }

        return count < limit
    }

    /// Records one free use. No-op for premium users.
    public func recordFreeMeasure() {
        if IAPHelper.shared.isPremium { return }

        let count = UserDefaults.standard.integer(forKey: freeMeasureCountKey)
        UserDefaults.standard.set(count + 1, forKey: freeMeasureCountKey)
        UserDefaults.standard.set(Date(), forKey: lastFreeMeasureDateKey)
    }

    /// Remaining free uses in the current interval. `Int.max` for premium users.
    public func getRemainingFreeMeasures() -> Int {
        if IAPHelper.shared.isPremium { return Int.max }

        let limit = config.getFreeMeasureLimitPerInterval()
        let count = UserDefaults.standard.integer(forKey: freeMeasureCountKey)
        let lastDate = UserDefaults.standard.object(forKey: lastFreeMeasureDateKey) as? Date

        if let lastDate = lastDate {
            let intervalHours = config.getFreeMeasureTimeInterval()
            let hoursSinceLastMeasure = Date().timeIntervalSince(lastDate) / 3600.0
            if hoursSinceLastMeasure >= Double(intervalHours) {
                return limit
            }
        }

        return max(0, limit - count)
    }

    /// Clears the free-use counter (e.g. for debugging or account reset).
    public func reset() {
        UserDefaults.standard.removeObject(forKey: freeMeasureCountKey)
        UserDefaults.standard.removeObject(forKey: lastFreeMeasureDateKey)
    }
}
