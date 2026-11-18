// swift-tools-version: 6.0
// Pixie Local voice helper: Kokoro-82M on the Neural Engine via FluidAudio, served on loopback.
import PackageDescription
let package = Package(
    name: "PixieVoice",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "16780f04d2ece24f67d0fc00efccd0296491c1a8")],
    targets: [.executableTarget(name: "PixieVoice", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], swiftSettings: [.swiftLanguageMode(.v5)])]
)
