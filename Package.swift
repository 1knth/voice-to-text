// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Whisper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Whisper", targets: ["Whisper"])],
    dependencies: [],
    targets: [
        .target(name: "WhisperCore"),
        .target(name: "WhisperCapture"),
        .executableTarget(name: "Whisper", dependencies: ["WhisperCore", "WhisperCapture"]),
        .testTarget(name: "WhisperCoreTests", dependencies: ["WhisperCore", "WhisperCapture"])
    ]
)
