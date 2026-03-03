// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-wit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Wit", targets: ["Wit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nathanborror/swift-mime", branch: "main"),
    ],
    targets: [
        .target(name: "Wit", dependencies: [
            .product(name: "MIME", package: "swift-mime"),
        ]),
        .testTarget(name: "WitTests", dependencies: ["Wit"]),
    ]
)
