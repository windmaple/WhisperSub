// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperSub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WhisperSub", targets: ["WhisperSub"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperSub",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
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
