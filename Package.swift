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
    targets: [
        .target(name: "Wit"),
        .testTarget(name: "WitTests", dependencies: ["Wit"]),
    ]
)
