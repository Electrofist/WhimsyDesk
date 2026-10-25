// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopDrawer",
    platforms: [.macOS(.v14)],   // NSView.displayLink(target:selector:) needs macOS 14
    targets: [
        .executableTarget(name: "DesktopDrawer", path: "Sources/DesktopDrawer")
    ]
)
