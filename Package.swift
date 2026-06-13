// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceFlow", targets: ["VoiceFlow"])
    ],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git", from: "1.10.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceFlow",
            dependencies: [
                .product(name: "sherpa-onnx", package: "sherpa-onnx")
            ],
            path: "VoiceFlow",
            resources: [
                // 暂时不需要硬编码资源，模型在运行时下载到 Application Support
            ],
            linkerSettings: [
                // 如果有特定系统库的连接要求可以在此配置
            ]
        )
    ]
)
