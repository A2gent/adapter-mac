// swift-tools-version: 5.9
// This is a placeholder - the actual build is handled by Xcode project

import PackageDescription

let package = Package(
    name: "adapter-mac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "adapter-mac",
            targets: ["adapter-mac"])
    ],
    targets: [
        .executableTarget(
            name: "adapter-mac",
            path: "stts")
    ]
)
