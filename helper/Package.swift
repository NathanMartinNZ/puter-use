// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PuterUseHelper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PuterUseHelper",
            path: "Sources/PuterUseHelper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        // A test window that logs the events it receives (see scripts/check_motion.py).
        .executableTarget(name: "PuterUseProbe", path: "Sources/PuterUseProbe", linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "PuterUseHelperTests", dependencies: ["PuterUseHelper"], path: "Tests/PuterUseHelperTests"),
    ]
)
