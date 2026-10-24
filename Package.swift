// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperSub",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "WhisperSub", targets: ["WhisperSub"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/john-rocky/CoreML-LLM.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "WhisperSub",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "CoreMLLLM", package: "CoreML-LLM")
            ],
            path: "Sources/WhisperSub",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreML"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
