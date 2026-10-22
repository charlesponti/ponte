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
        // Local checkout while the capture target settles; by URL once tagged.
        .package(path: "../Waveform"),
    ],
    targets: [
        .executableTarget(
            name: "Ponte",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WaveformCore", package: "Waveform"),
                .product(name: "WaveformUI", package: "Waveform"),
                .product(name: "WaveformCapture", package: "Waveform"),
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
