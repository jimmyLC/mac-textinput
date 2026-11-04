// swift-tools-version:5.9
import PackageDescription

// Kept apart from the engine: ZhizhiCore and the IME must build without MLX.
let package = Package(
    name: "ZhizhiAI",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "zhizhi-ai", targets: ["zhizhi-ai"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.33.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.4.0"),
    ],
    targets: [
        .executableTarget(name: "zhizhi-ai", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
    ]
)
