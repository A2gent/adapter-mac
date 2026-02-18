// swift-tools-version: 5.9
// This is a placeholder - the actual build is handled by Xcode project

import PackageDescription

let package = Package(
    name: "stts",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "stts",
            targets: ["stts"])
    ],
    targets: [
        .executableTarget(
            name: "stts",
            path: "stts")
    ]
)
