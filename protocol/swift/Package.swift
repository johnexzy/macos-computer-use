// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UseUIProtocol",
    platforms: [.macOS(.v13)],
    products: [.library(name: "UseUIProtocol", targets: ["UseUIProtocol"])],
    targets: [
        .target(name: "UseUIProtocol"),
        .testTarget(name: "UseUIProtocolTests", dependencies: ["UseUIProtocol"]),
    ]
)
