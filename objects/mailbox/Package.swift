// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopMailbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DesktopMailbox", path: "Sources/DesktopMailbox")
    ],
    swiftLanguageVersions: [.v5]
)
