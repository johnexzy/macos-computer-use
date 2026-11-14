// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CUAProtocol",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CUAProtocol", targets: ["CUAProtocol"])],
    targets: [
        .target(name: "CUAProtocol"),
        .testTarget(name: "CUAProtocolTests", dependencies: ["CUAProtocol"]),
    ]
)
