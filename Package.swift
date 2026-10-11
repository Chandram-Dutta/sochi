// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sochi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sochi", targets: ["sochi"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "sochi",
            dependencies: [
                "SochiKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "SochiKit"),
        .testTarget(name: "SochiKitTests", dependencies: ["SochiKit"]),
    ]
)
