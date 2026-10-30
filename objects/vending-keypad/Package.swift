// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopVendingKeypad",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DesktopVendingKeypad", path: "Sources/DesktopVendingKeypad")
    ],
    swiftLanguageVersions: [.v5]
)
