// swift-tools-version: 5.9
//
//  Package.swift
//  SwiftIAP
//
//  Native StoreKit 2 in-app-purchase toolkit, extracted into a reusable package.
//

import PackageDescription

let package = Package(
    name: "SwiftIAP",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "SwiftIAP",
            targets: ["SwiftIAP"]
        )
    ],
    targets: [
        .target(
            name: "SwiftIAP"
        ),
        .testTarget(
            name: "SwiftIAPTests",
            dependencies: ["SwiftIAP"]
        )
    ]
)
