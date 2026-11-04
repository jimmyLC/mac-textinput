// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zhizhi",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ZhizhiCore", targets: ["ZhizhiCore"])],
    targets: [
        .target(name: "ZhizhiCore"),
        .executableTarget(name: "zhizhi-eval", dependencies: ["ZhizhiCore"]),
        .testTarget(name: "ZhizhiCoreTests", dependencies: ["ZhizhiCore"]),
    ]
)
