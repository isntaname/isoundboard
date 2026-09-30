// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Soundboard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SoundboardCore", targets: ["SoundboardCore"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "InputControl", targets: ["InputControl"]),
        .executable(name: "soundboardctl", targets: ["soundboardctl"]),
        .executable(name: "SoundboardApp", targets: ["SoundboardApp"]),
    ],
    targets: [
        // Portable. No platform APIs — this is the only layer a future
        // Windows build reuses.
        .target(name: "SoundboardCore"),

        .target(name: "AudioEngine", dependencies: ["SoundboardCore"]),
        .target(name: "InputControl", dependencies: ["SoundboardCore"]),

        .executableTarget(name: "SoundboardApp",
                          dependencies: ["AudioEngine", "InputControl", "SoundboardCore"]),

        // Verification harness for the parts that need real audio hardware.
        .executableTarget(name: "soundboardctl",
                          dependencies: ["AudioEngine", "InputControl", "SoundboardCore"]),

        .testTarget(name: "SoundboardCoreTests", dependencies: ["SoundboardCore"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine"]),
        .testTarget(name: "InputControlTests", dependencies: ["InputControl"]),
    ]
)
