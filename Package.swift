// swift-tools-version: 6.2
//
// Test harness for CostcoTracker's Analytics cloud sync logic. The app target
// compiles CostcoTracker/AnalyticsSync directly (synchronized folder); this
// package compiles the very same files as a module so they can be unit-tested
// with `swift test` on macOS without a simulator. It is not linked into the app.
import PackageDescription

let appLikeSettings: [SwiftSetting] = [
    // Match the app target: Swift 5 mode, MainActor by default, approachable concurrency.
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "CostcoTrackerAnalyticsSync",
    platforms: [.macOS(.v15), .iOS(.v18)],
    targets: [
        .target(
            name: "AnalyticsSync",
            path: "CostcoTracker/AnalyticsSync",
            swiftSettings: appLikeSettings
        ),
        .testTarget(
            name: "AnalyticsSyncTests",
            dependencies: ["AnalyticsSync"],
            path: "Tests/AnalyticsSyncTests",
            exclude: ["Fixtures"],
            swiftSettings: appLikeSettings
        ),
    ]
)
