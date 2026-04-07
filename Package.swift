// swift-tools-version: 5.9
// This is a placeholder - the actual build is handled by Xcode project

import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "scribe",
            targets: ["scribe"])
    ],
    targets: [
        .executableTarget(
            name: "scribe",
            path: "stts")
    ]
)
