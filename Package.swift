// swift-tools-version: 5.9

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
            path: "stts",
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "Resources"
            ]
        ),
        .testTarget(
            name: "AdapterMacTests",
            dependencies: ["adapter-mac"],
            path: "Tests/AdapterMacTests"
        )
    ]
)
