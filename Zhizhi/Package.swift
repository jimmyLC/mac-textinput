// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zhizhi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZhizhiCore", targets: ["ZhizhiCore"]),
        .executable(name: "Zhizhi", targets: ["Zhizhi"]),
        .executable(name: "ZhizhiApp", targets: ["ZhizhiApp"]),
    ],
    targets: [
        .target(name: "ZhizhiCore"),
        .executableTarget(name: "zhizhi-eval", dependencies: ["ZhizhiCore"]),
        .executableTarget(name: "Zhizhi", dependencies: ["ZhizhiCore"], path: "Sources/ZhizhiIME"),
        .executableTarget(name: "ZhizhiApp", dependencies: ["ZhizhiCore"]),
        .testTarget(name: "ZhizhiCoreTests", dependencies: ["ZhizhiCore"]),
    ]
)
