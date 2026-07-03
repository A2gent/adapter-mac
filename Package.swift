// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "adapter-mac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "adapter-mac",
            targets: ["adapter-mac"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        .package(url: "https://github.com/ggerganov/whisper.spm.git", branch: "master")
    ],
    targets: [
        .executableTarget(
            name: "adapter-mac",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "whisper", package: "whisper.spm")
            ],
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
