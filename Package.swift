// swift-tools-version:6.0
import PackageDescription

// Builds a bare executable. The runnable artifact is the .app bundle the
// Makefile assembles around it (`make app`) — TCC attributes the screen
// recording and microphone grants to that bundle, so there is no longer an
// Info.plist stitched into the binary with -sectcreate. Run the copy inside
// the bundle, not .build/release/trailmix directly, or the microphone prompt
// has no usage string and macOS kills the process.
let package = Package(
    name: "trailmix",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "trailmix",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
