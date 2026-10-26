import Foundation

/// Optional user config at ~/.config/trailmix/config.json:
///
///     {
///       "recordings_dir": "~/Trailmix",
///       "sources": { "computer_audio": true, "microphone": true },
///       "capture": { "mode": "none", "display_id": null, "fps": 30, "codec": "hevc" },
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "echo_cancellation": true,
///       "max_recording_hours": 8,
///       "hotkey": "cmd+shift+7",
///       "on_stop": "my-hook"
///     }
///
/// Parsed once at startup, not per accessor. The source selections are read
/// on every menu open and every recording, and a config that changed halfway
/// through a session used to mean a recording made under one setting and
/// hooked under another.
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Trailmix. `on_stop` is a shell command spawned with the session
/// directory as its argument, after the transcript is written (or right after
/// recording when transcription is disabled).
struct Config: Sendable {
    struct Sources: Sendable, Equatable {
        var computerAudio: Bool
        var microphone: Bool

        static let `default` = Sources(computerAudio: true, microphone: true)
    }

    struct Capture: Sendable {
        /// Persisted capture mode. Window selections are deliberately absent:
        /// CGWindowID isn't stable across launches, so a saved window target
        /// would silently point at something else. Windows reset to `none`.
        enum Mode: String, Sendable {
            case none
            case display
        }

        var mode: Mode
        /// CGDirectDisplayID, or nil for the main display. A saved ID that no
        /// longer matches an attached display falls back to main.
        var displayID: UInt32?
        var fps: Int
        /// "hevc" or "h264"; anything else falls back to hevc at stream setup,
        /// which also checks availableVideoCodecTypes.
        var codec: String

        static let `default` = Capture(mode: .none, displayID: nil, fps: 30, codec: "hevc")
    }

    var recordingsDir: URL?
    var sources: Sources
    var capture: Capture
    var transcriptionEnabled: Bool
    var transcriptionEngine: String
    /// Route the mic through the voice-processing IO unit so system audio
    /// playing through the speakers doesn't land in the mic track too. Off
    /// puts the mic back on ScreenCaptureKit, raw and un-gained.
    var echoCancellation: Bool
    /// Hard cap on any recording, applied even when no timer was set from the
    /// menu, so a recording started before a meeting and forgotten can't fill
    /// the disk overnight. Zero or negative disables it. Read-only: the menu
    /// never writes this, since a backstop you can move from the menu is one
    /// you can move by accident.
    var maxRecordingHours: Double
    /// System-wide start/stop shortcut, e.g. "cmd+shift+7"; "none" disables
    /// it. See `GlobalHotkey.Combo.parse` for what is accepted.
    var hotkey: String
    var onStop: String?

    static let path = Paths.config

    /// Where recordings go when nothing overrides it. See `Paths`.
    static let defaultRoot = Paths.defaultRecordingsRoot

    static let `default` = Config(
        recordingsDir: nil,
        sources: .default,
        capture: .default,
        transcriptionEnabled: true,
        transcriptionEngine: "parakeet",
        echoCancellation: true,
        maxRecordingHours: 8,
        hotkey: "cmd+shift+7",
        onStop: nil
    )

    /// The process-wide config, parsed on first access. A malformed file is
    /// reported rather than silently ignored, since recordings landing in
    /// an unexpected place is worse than a warning.
    static let current: Config = load()

    private static func load() -> Config {
        guard FileManager.default.fileExists(atPath: path.path) else { return .default }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Through Log, not straight to stderr: launched from Finder or at
            // login there is no terminal, and a config silently ignored is how
            // recordings end up somewhere nobody expects.
            Log.warn("\(path.path) is not valid JSON, ignoring config")
            return .default
        }

        var config = Config.default

        if let dir = json["recordings_dir"] as? String, !dir.isEmpty {
            config.recordingsDir = URL(
                fileURLWithPath: (dir as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        if let sources = json["sources"] as? [String: Any] {
            config.sources = Sources(
                computerAudio: sources["computer_audio"] as? Bool ?? Sources.default.computerAudio,
                microphone: sources["microphone"] as? Bool ?? Sources.default.microphone
            )
        }
        if let capture = json["capture"] as? [String: Any] {
            config.capture = Capture(
                mode: (capture["mode"] as? String).flatMap(Capture.Mode.init) ?? .none,
                displayID: (capture["display_id"] as? NSNumber)?.uint32Value,
                fps: capture["fps"] as? Int ?? Capture.default.fps,
                codec: capture["codec"] as? String ?? Capture.default.codec
            )
        }
        if let transcription = json["transcription"] as? [String: Any] {
            config.transcriptionEnabled =
                transcription["enabled"] as? Bool ?? config.transcriptionEnabled
            config.transcriptionEngine =
                transcription["engine"] as? String ?? config.transcriptionEngine
        }
        if let echo = json["echo_cancellation"] as? Bool {
            config.echoCancellation = echo
        }
        if let hours = (json["max_recording_hours"] as? NSNumber)?.doubleValue {
            config.maxRecordingHours = hours
        }
        if let hotkey = json["hotkey"] as? String {
            config.hotkey = hotkey
        }
        if let cmd = json["on_stop"] as? String, !cmd.isEmpty {
            config.onStop = cmd
        }
        return config
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return current.recordingsDir ?? defaultRoot
    }

    /// Persist a new recordings root chosen from the menu.
    ///
    /// Written as a literal path rather than re-tilde'd: the picker hands back
    /// an absolute URL and round-tripping it through `~` would only introduce
    /// a way to get it wrong. Hand-written configs can still use `~`, which
    /// `load()` expands.
    static func persistRecordingsDir(_ url: URL) {
        update { $0["recordings_dir"] = url.path }
    }

    /// Write the source and capture selections back, preserving every other
    /// key in the file. The menu is the primary way these change, so a toggle
    /// has to survive a restart without clobbering hand-edited settings.
    static func persistSelections(sources: Sources, capture: Capture) {
        update { json in
            json["sources"] = [
                "computer_audio": sources.computerAudio,
                "microphone": sources.microphone,
            ]
            var captureJSON: [String: Any] = [
                "mode": capture.mode.rawValue,
                "fps": capture.fps,
                "codec": capture.codec,
            ]
            if let displayID = capture.displayID {
                captureJSON["display_id"] = displayID
            }
            json["capture"] = captureJSON
        }
    }

    /// Read-modify-write the config file, preserving every key the caller
    /// doesn't touch. Settings the menu can change and settings only reachable
    /// by hand live in the same file, and a menu click must never be what
    /// silently drops someone's hand-written `on_stop`.
    private static func update(_ change: (inout [String: Any]) -> Void) {
        var json = (try? Data(contentsOf: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { $0 as? [String: Any] } ?? [:]
        change(&json)

        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: path, options: .atomic)
        } catch {
            Log.warn("couldn't save settings to \(path.path): \(error)")
        }
    }
}
