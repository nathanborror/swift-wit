// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-wit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "Wit", targets: ["Wit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nathanborror/swift-mime-generated", branch: "main"),
    ],
    targets: [
        .target(name: "Wit", dependencies: [
            .product(name: "MIME", package: "swift-mime-generated"),
        ]),
        .testTarget(name: "WitTests", dependencies: ["Wit"]),
    ]
)
