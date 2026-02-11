// swift-tools-version: 6.1
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
        .executable(
            name: "findit-mcp-server",
            targets: ["FindItMCPServer"]
        ),
    ],
    dependencies: [
        // SQLite ORM + FTS5 全文搜索
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.0")),
        // CLI 参数解析
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // MCP (Model Context Protocol) Server SDK
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),

        // --- 以下依赖在后续阶段启用 ---
        // Stage 2: WhisperKit STT (v0.15.x, pre-1.0 可能有破坏性变更)
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.15.0")),
        // Stage 3.5: MLX Swift for 本地 VLM 推理
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", .upToNextMinor(from: "2.30.3")),
        // Stage R2a: ONNX Runtime for SigLIP2 CLIP 视觉嵌入
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
        // Stage R2a: SentencePiece tokenizer for SigLIP2 text encoder
        .package(url: "https://github.com/jkrukowski/swift-sentencepiece.git", from: "0.0.3"),
        // Stage R2b: USearch HNSW 向量索引
        .package(url: "https://github.com/unum-cloud/usearch", from: "2.0.0"),
    ],
    targets: [
        // xxHash C 库（嵌入官方 v0.8.3 源码，BSD 2-Clause）
        .target(
            name: "CxxHash",
            path: "Sources/CxxHash",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FindItCore",
            dependencies: [
                "CxxHash",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "SentencepieceTokenizer", package: "swift-sentencepiece"),
                .product(name: "USearch", package: "usearch"),
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
            name: "FindItMCPServer",
            dependencies: [
                "FindItCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk"),
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
        .testTarget(
            name: "FindItMCPServerTests",
            dependencies: [
                "FindItMCPServer",
                "FindItCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
