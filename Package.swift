// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuaRuntime",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CUARuntime", targets: ["CUARuntime"]),
        .executable(name: "cua-runtime", targets: ["cua-runtime"]),
    ],
    dependencies: [.package(path: "protocol/swift")],
    targets: [
        .target(name: "CUARuntime", dependencies: [.product(name: "CUAProtocol", package: "swift")], path: "runtime/Sources/CUARuntime"),
        .executableTarget(name: "cua-runtime", dependencies: ["CUARuntime", .product(name: "CUAProtocol", package: "swift")], path: "runtime/Sources/cua-runtime"),
        .testTarget(name: "CUARuntimeTests", dependencies: ["CUARuntime"], path: "runtime/Tests/CUARuntimeTests"),
    ]
)
