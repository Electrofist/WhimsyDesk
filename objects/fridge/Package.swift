// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopFridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DesktopFridge", targets: ["DesktopFridge"])
    ],
    targets: [
        // Pure Foundation logic: door physics, frost model, ~/Fridge store, shelf layout.
        .target(
            name: "FridgeCore",
            path: "Sources/FridgeCore"
        ),
        // AppKit + Core Animation app.
        .executableTarget(
            name: "DesktopFridge",
            dependencies: ["FridgeCore"],
            path: "Sources/DesktopFridge"
        ),
        .testTarget(
            name: "FridgeCoreTests",
            dependencies: ["FridgeCore"],
            path: "Tests/FridgeCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
