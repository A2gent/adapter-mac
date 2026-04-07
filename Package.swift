// swift-tools-version: 5.9
// This is a placeholder - the actual build is handled by Xcode project

import PackageDescription

let package = Package(
    name: "parselton",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "parselton",
            targets: ["parselton"])
    ],
    targets: [
        .executableTarget(
            name: "parselton",
            path: "stts")
    ]
)
