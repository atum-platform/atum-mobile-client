// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AtumDesign",
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [.library(name: "AtumDesign", targets: ["AtumDesign"]),
               .library(name: "AtumPrototype", targets: ["AtumPrototype"]),
               .library(name: "AtumNativeAPI", targets: ["AtumNativeAPI"]),
               .library(name: "AtumDrive", targets: ["AtumDrive"]),
               .library(name: "AtumChat", targets: ["AtumChat"]),
               .library(name: "AtumTelemetry", targets: ["AtumTelemetry"])],
    targets: [
        .target(name: "AtumDesign", path: ".", exclude: ["Tests", "App", "AppTests", "Notifications", "UITests", "Sources/AtumPrototype", "Sources/AtumNativeAPI", "Sources/AtumDrive", "Sources/AtumChat", "ExportOptions.plist", "project.yml", "AtumMobile.xcodeproj", "DerivedData", "sdk-baseline.json", "Vendor/AtumKitIcons"],
                sources: ["Sources/AtumDesign"], resources: [.copy("Vendor/AtumDesign")]),
        .target(name: "AtumPrototype", dependencies: ["AtumDesign", "AtumNativeAPI"], path: "Sources/AtumPrototype", resources: [.copy("Fixtures")]),
        .target(name: "AtumNativeAPI", path: "Sources/AtumNativeAPI"),
        .target(name: "AtumDrive", dependencies: ["AtumNativeAPI"],
                path: "Sources/AtumDrive", resources: [.copy("Resources/DriveStageACopy.json")]),
        // Pure chat core of the revamp (plan §2.2): no SDK, no SwiftUI, no UIKit.
        .target(name: "AtumChat", path: "Sources/AtumChat"),
        .target(name: "AtumTelemetry", path: "Sources/AtumTelemetry"),
        .testTarget(name: "AtumDesignTests", dependencies: ["AtumDesign", "AtumPrototype", "AtumNativeAPI", "AtumChat"], path: "Tests",
                    exclude: ["AtumChat", "AtumDrive", "AtumTelemetry"],
                    resources: [.copy("Fixtures/model-choice-v1.3"),
                                .copy("Fixtures/agent-home-v2.5"),
                                .copy("Fixtures/live-platform-2026-10-28"),
                                .copy("Fixtures/company-workspace-v1.1"),
                                .copy("Fixtures/company-private-cos"),
                                .copy("Fixtures/company-workspace-v1.5"),
                                .copy("Fixtures/company-workspace-v1.3-capabilities"),
                                .copy("Fixtures/mobile-drive-v1"),
                                .copy("Fixtures/opencloud-drive-graph")]),
        .testTarget(name: "AtumChatTests", dependencies: ["AtumChat"], path: "Tests/AtumChat"),
        .testTarget(name: "AtumDriveTests", dependencies: ["AtumDrive", "AtumNativeAPI"],
                    path: "Tests/AtumDrive"),
        .testTarget(name: "AtumTelemetryTests", dependencies: ["AtumTelemetry"],
                    path: "Tests/AtumTelemetry")
    ]
)
