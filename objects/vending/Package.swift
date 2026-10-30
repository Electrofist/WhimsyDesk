// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopVendingMachine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DesktopVendingMachine", path: "Sources/DesktopVendingMachine")
    ],
    swiftLanguageVersions: [.v5]
)
