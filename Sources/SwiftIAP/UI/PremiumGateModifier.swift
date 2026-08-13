//
//  PremiumGateModifier.swift
//  SwiftIAP
//
//  The "blur + dim + locked overlay" pattern for premium-gated content.
//  The overlay is supplied by the host app (its own design), so the package
//  carries no assets or colors.
//
//  Usage:
//      mySection
//          .premiumGated {
//              MyPremiumLockedView(title: "EKG")
//          }
//

import SwiftUI

public struct PremiumGateModifier<Overlay: View>: ViewModifier {
    private let blurRadius: CGFloat
    private let dimmedOpacity: Double
    private let overlay: () -> Overlay

    /// Observes premium state so the gate flips live on purchase / restore.
    @ObservedObject private var helper = IAPHelper.shared

    public init(
        blurRadius: CGFloat,
        dimmedOpacity: Double,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.blurRadius = blurRadius
        self.dimmedOpacity = dimmedOpacity
        self.overlay = overlay
    }

    public func body(content: Content) -> some View {
        let gated = helper.shouldGatePremium
        ZStack {
            content
                .blur(radius: gated ? blurRadius : 0)
                .opacity(gated ? dimmedOpacity : 1)

            if gated {
                overlay()
            }
        }
    }
}

public extension View {
    /// Blurs the view and overlays `lockedOverlay` when the user does not have
    /// premium access. No-op when the user is premium or IAP is disabled via
    /// remote config.
    func premiumGated<Overlay: View>(
        blurRadius: CGFloat = 8,
        dimmedOpacity: Double = 0.3,
        @ViewBuilder lockedOverlay: @escaping () -> Overlay
    ) -> some View {
        modifier(PremiumGateModifier(
            blurRadius: blurRadius,
            dimmedOpacity: dimmedOpacity,
            overlay: lockedOverlay
        ))
    }
}
