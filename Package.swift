// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-git",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "Git", targets: ["Git"]),
    ],
    targets: [
        .target(name: "Git"),
        .testTarget(name: "GitTests", dependencies: ["Git"]),
    ]
)
