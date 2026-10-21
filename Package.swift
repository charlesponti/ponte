// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceNote",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT / Unified ASR on the Apple Neural Engine via CoreML.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceNote",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VoiceNote",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
