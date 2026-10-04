// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DesktopToolServer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DesktopToolServer", targets: ["DesktopToolServer"])],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            revision: "6132fd4b5b4217ce4717c4775e4607f5c3120129")
    ],
    targets: [
        .executableTarget(
            name: "DesktopToolServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]),
        .testTarget(
            name: "DesktopToolServerTests",
            dependencies: [
                "DesktopToolServer", .product(name: "MCP", package: "swift-sdk"),
            ]),
    ])
