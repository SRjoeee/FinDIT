// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FindIt",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FindItCore",
            targets: ["FindItCore"]
        ),
        .executable(
            name: "findit-cli",
            targets: ["FindItCLI"]
        ),
    ],
    dependencies: [
        // SQLite ORM + FTS5 全文搜索
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.0")),
        // CLI 参数解析
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),

        // --- 以下依赖在后续阶段启用 ---
        // Stage 2: WhisperKit STT (v0.15.x, pre-1.0 可能有破坏性变更)
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.15.0")),
        // Stage 3.5: MLX Swift for 本地 VLM 推理
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", .upToNextMinor(from: "2.30.3")),
        // Stage 3: ONNX Runtime for BGE-M3 向量嵌入
        // .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "FindItCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
        ),
        .executableTarget(
            name: "FindItCLI",
            dependencies: [
                "FindItCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "FindItApp",
            dependencies: [
                "FindItCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "FindItCoreTests",
            dependencies: ["FindItCore"]
        ),
    ]
)
