// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ponte",
    // macOS 15 because WaveformCore/Capture require it: the shared recording engine and the orb
    // maths were lifted out of Ponte and Thames into one tested package (see ../Waveform).
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet TDT / Unified ASR on the Apple Neural Engine via CoreML.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.0"),
        // The orb maths, the orb view and the recording engine, shared with Thames.
        .package(url: "https://github.com/charlesponti/waveform.git", from: "0.5.0"),
        // Updates. The one network request the app makes, and only to fetch its own appcast — see #6. Sparkle's
        // product is a prebuilt binary target, so this pulls a signed framework rather than compiling one.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Ponte",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WaveformCore", package: "waveform"),
                .product(name: "WaveformUI", package: "waveform"),
                .product(name: "WaveformCapture", package: "waveform"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Ponte",
            // The app's own code is Swift 5: the manifest has to be 6.0 to name macOS 15, but
            // strict concurrency across the AppKit paths is a separate, later job.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "PonteTests",
            dependencies: ["Ponte"],
            path: "Tests/PonteTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
