// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VideoDAW",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure value-type project model and edits. No framework dependencies.
        .target(name: "Model"),
        // C++ / Objective-C++ engine behind a plain C header.
        .target(
            name: "Engine",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                .linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
                .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"), .linkedFramework("AppKit"),
                .linkedFramework("CoreAudioKit"),
            ]
        ),
        // Plan compiler, project store, Swift wrapper over the engine.
        .target(name: "Session", dependencies: ["Model", "Engine"]),
        .executableTarget(name: "VideoDAW", dependencies: ["Session", "Model"]),
        .testTarget(name: "ModelTests", dependencies: ["Model"]),
        .testTarget(name: "SessionTests", dependencies: ["Session", "Model"]),
    ],
    cxxLanguageStandard: .cxx20
)
