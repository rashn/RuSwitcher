// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RuSwitcher",
            path: "Sources/RuSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
