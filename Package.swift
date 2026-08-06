// swift-tools-version:6.0
import PackageDescription

// Builds a bare executable. The runnable artifact is the .app bundle the
// Makefile assembles around it (`make app`). TCC attributes the screen
// recording and microphone grants to that bundle, so there is no longer an
// Info.plist stitched into the binary with -sectcreate. Run the copy inside
// the bundle, not .build/release/trailmix directly, or the microphone prompt
// has no usage string and macOS kills the process.
let package = Package(
    name: "trailmix",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Pinned to a minor line, not `from: "0.7.0"`. FluidAudio is pre-1.0, so
        // `from:` permits anything below 1.0 and a `swift package update` can
        // walk the API out from under `ParakeetEngine`. That is not
        // hypothetical in either direction: `WordTiming` and `buildWordTimings`
        // do not exist in 0.7 at all, so the old floor never built. 0.15.5 is
        // what the resolver has been picking and what every recording so far was
        // transcribed with.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
    ],
    targets: [
        .executableTarget(
            name: "trailmix",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // Tests cover the pure, load-bearing parts: duration parsing, the
        // session filenames, and the doctor report's rendering. No AppKit, no
        // model, no capture. Those need a click, a screen and a microphone,
        // and are still checked by hand.
        .testTarget(
            name: "trailmixTests",
            dependencies: ["trailmix"]
        ),
    ]
)
