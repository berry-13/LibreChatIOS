// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LibreChatCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LibreChatDomain", targets: ["LibreChatDomain"]),
        .library(name: "LibreChatProtocol", targets: ["LibreChatProtocol"]),
        .library(name: "LibreChatTestSupport", targets: ["LibreChatTestSupport"]),
        .library(name: "DesignKit", targets: ["DesignKit"])
    ],
    targets: [
        .target(name: "LibreChatDomain"),
        .target(
            name: "LibreChatProtocol",
            dependencies: ["LibreChatDomain"]
        ),
        .target(
            name: "LibreChatTestSupport",
            dependencies: ["LibreChatDomain", "LibreChatProtocol"]
        ),
        .target(name: "DesignKit"),
        .testTarget(
            name: "LibreChatProtocolTests",
            dependencies: ["LibreChatDomain", "LibreChatProtocol", "LibreChatTestSupport", "DesignKit"]
        )
    ]
)
