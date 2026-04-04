// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RetroGate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RetroGate", targets: ["RetroGate"]),
        // Library products for Xcode app target linking
        .library(name: "ProxyServer", targets: ["ProxyServer"]),
        .library(name: "HTMLTranscoder", targets: ["HTMLTranscoder"]),
        .library(name: "ImageTranscoder", targets: ["ImageTranscoder"]),
    ],
    dependencies: [
        // High-performance async HTTP server
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        // HTML parsing & DOM manipulation (like Jsoup for Swift)
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        // Argument parser for optional CLI mode
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Main app target (SwiftUI + entry point)
        .executableTarget(
            name: "RetroGate",
            dependencies: [
                "ProxyServer",
                "HTMLTranscoder",
                "WaybackBridge",
                "ImageTranscoder",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // HTTP/HTTPS proxy server built on SwiftNIO
        .target(
            name: "ProxyServer",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                "HTMLTranscoder",
                "ImageTranscoder",
                "WaybackBridge",
            ]
        ),
        // HTML5 → HTML 3.2 transcoder
        .target(
            name: "HTMLTranscoder",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Wayback Machine URL rewriter & response cleaner
        .target(
            name: "WaybackBridge",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Image format conversion (WebP/AVIF → JPEG/GIF) & resizing
        .target(
            name: "ImageTranscoder",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Tests
        .testTarget(
            name: "RetroGateTests",
            dependencies: ["HTMLTranscoder", "WaybackBridge", "ProxyServer"]
        ),
    ]
)
