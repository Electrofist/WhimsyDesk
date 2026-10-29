// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "__EXEC__",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "__EXEC__", path: "Sources/__EXEC__")
    ],
    swiftLanguageVersions: [.v5]
)
