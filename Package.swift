// swift-tools-version: 6.0
import PackageDescription

let vendor = "\(Context.packageDirectory)/Vendor"
let llamaLink: [LinkerSetting] = [.unsafeFlags(["-L\(vendor)/llama/lib"])]

let package = Package(
    name: "CortexRAG",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CortexCore", targets: ["CortexCore"]),
        .library(name: "CortexEmbedders", targets: ["CortexEmbedders"]),
        .library(name: "CortexVision", targets: ["CortexVision"]),
        .library(name: "CortexIPC", targets: ["CortexIPC"]),
        .executable(name: "CortexRAGApp", targets: ["CortexRAGApp"]),
        .executable(name: "cortexrag", targets: ["cortexrag-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ],
    targets: [
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        .target(
            name: "EmbeddingGemma2MLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/EmbeddingGemma2MLX"
        ),
        .target(
            name: "CortexCore",
            dependencies: [],
            path: "Sources/CortexCore",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Accelerate"), .linkedFramework("IOKit")]
        ),
        .target(
            name: "CortexEmbedders",
            dependencies: ["CortexCore", "CLlama", "EmbeddingGemma2MLX"],
            path: "Sources/CortexEmbedders",
            linkerSettings: llamaLink
        ),
        .target(
            name: "CortexVision",
            dependencies: ["CortexCore"],
            path: "Sources/CortexVision",
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AppKit")
            ]
        ),
        .target(
            name: "CortexIPC",
            dependencies: ["CortexCore", "CortexEmbedders", "CortexVision"],
            path: "Sources/CortexIPC",
            linkerSettings: llamaLink
        ),
        .executableTarget(
            name: "CortexRAGApp",
            dependencies: ["CortexCore", "CortexEmbedders", "CortexVision", "CortexIPC"],
            path: "Sources/CortexRAGApp",
            linkerSettings: llamaLink
        ),
        .executableTarget(
            name: "cortexrag-cli",
            dependencies: ["CortexCore", "CortexEmbedders", "CortexVision", "CortexIPC"],
            path: "Sources/cortexrag-cli",
            linkerSettings: llamaLink
        ),
        .testTarget(
            name: "CortexRAGTests",
            dependencies: ["CortexCore", "CortexEmbedders", "CortexVision", "CortexIPC", "CortexRAGApp"],
            path: "Tests/CortexRAGTests",
            linkerSettings: llamaLink
        )
    ]
)
