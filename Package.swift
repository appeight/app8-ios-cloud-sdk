// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "App8Cloud",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "App8Cloud", targets: ["App8Cloud"]),
    ],
    dependencies: [
        // The rendering engine lives in its own public repo. Pinned `exact`
        // while pre-1.0 — `from:` on a 0.x version allows the whole 0.x range.
        .package(url: "https://github.com/appeight/app8-ios-sdk.git", exact: "0.2.0"),
    ],
    targets: [
        .target(
            name: "App8Cloud",
            dependencies: [
                .product(name: "App8Engine", package: "app8-ios-sdk"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "App8CloudTests",
            dependencies: ["App8Cloud"]
        ),
    ]
)
