// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WhisperCore", targets: ["WhisperCore"]),
        .executable(name: "whispercore-cli", targets: ["whispercore-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "WhisperCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "whispercore-cli",
            dependencies: ["WhisperCore"]
        ),
        .testTarget(
            name: "WhisperCoreTests",
            dependencies: ["WhisperCore"]
        ),
    ]
)
