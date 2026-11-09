// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spool",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure strip model and layout maths. No AppKit, so it is unit-testable.
        .target(name: "SpoolCore"),
        .executableTarget(name: "Spool", dependencies: ["SpoolCore"]),
        // Command line front end: turns words into spool:// URLs for the running app.
        .executableTarget(name: "spoolctl", dependencies: ["SpoolCore"]),
        .testTarget(name: "SpoolCoreTests", dependencies: ["SpoolCore"]),
    ]
)
