// swift-tools-version:6.1
import PackageDescription

// Vocello-specialized fork: Qwen3-TTS only (2026-06-09).
// The upstream multi-model targets (STT/STS/VAD/LID/G2P/UI/Tools and the
// non-Mimi codec families) were deleted — restorable from upstream
// (Blaizzy/mlx-audio-swift @ fcbd04d) or git history. MLXAudioCodecs remains
// as the home of the Mimi transformer/conv/quantization primitives the
// Qwen3 speech tokenizer builds on.
let package = Package(
    name: "MLXAudio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Core foundation library
        .library(name: "MLXAudioCore", targets: ["MLXAudioCore"]),

        // Audio codec primitives (Mimi subset used by Qwen3-TTS)
        .library(name: "MLXAudioCodecs", targets: ["MLXAudioCodecs"]),

        // Text-to-Speech (Qwen3-TTS)
        .library(name: "MLXAudioTTS", targets: ["MLXAudioTTS"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.30.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.30.6"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0")
    ],
    targets: [
        // MARK: - MLXAudioCore
        .target(
            name: "MLXAudioCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioCore",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"], .when(configuration: .debug))
            ]
        ),

        // MARK: - MLXAudioCodecs
        .target(
            name: "MLXAudioCodecs",
            dependencies: [
                "MLXAudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioCodecs"
        ),

        // MARK: - MLXAudioTTS
        .target(
            name: "MLXAudioTTS",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioTTS"
        ),

        // Curated deterministic coverage for the owned Qwen3 runtime. Keep this
        // target narrow; do not re-import upstream's broad multi-model test tree.
        .testTarget(
            name: "Qwen3RuntimeTests",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                "MLXAudioTTS",
            ],
            path: "Tests/Qwen3RuntimeTests"
        ),
    ]
)
