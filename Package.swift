// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UseUIRuntime",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UseUIRuntime", targets: ["UseUIRuntime"]),
        .executable(name: "useui-runtime", targets: ["useui-runtime"]),
    ],
    dependencies: [.package(path: "protocol/swift")],
    targets: [
        .target(name: "UseUIRuntime", dependencies: [.product(name: "UseUIProtocol", package: "swift")], path: "runtime/Sources/UseUIRuntime"),
        .executableTarget(name: "useui-runtime", dependencies: ["UseUIRuntime", .product(name: "UseUIProtocol", package: "swift")], path: "runtime/Sources/useui-runtime"),
        .testTarget(name: "UseUIRuntimeTests", dependencies: ["UseUIRuntime"], path: "runtime/Tests/UseUIRuntimeTests"),
    ]
)
