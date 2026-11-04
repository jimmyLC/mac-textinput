// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zhizhi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZhizhiCore", targets: ["ZhizhiCore"]),
        .executable(name: "Zhizhi", targets: ["Zhizhi"]),
    ],
    targets: [
        .target(name: "ZhizhiCore"),
        .executableTarget(name: "zhizhi-eval", dependencies: ["ZhizhiCore"]),
        .executableTarget(name: "Zhizhi", dependencies: ["ZhizhiCore"], path: "Sources/ZhizhiIME"),
        .testTarget(name: "ZhizhiCoreTests", dependencies: ["ZhizhiCore"]),
    ]
)
