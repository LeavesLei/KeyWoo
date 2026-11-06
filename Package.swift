// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyDance",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "KeyDance", targets: ["KeyDance"])],
    targets: [
        .target(name: "AudioAtomics", publicHeadersPath: "include"),
        .executableTarget(name: "KeyDance", dependencies: ["AudioAtomics"], resources: [.copy("Resources/Music"), .copy("Resources/AI"), .copy("Resources/KeyboardSounds")]),
        .testTarget(name: "KeyDanceTests", dependencies: ["KeyDance"])
    ],
    swiftLanguageVersions: [.v5]
)
