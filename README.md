# trailmix

A minimal, fully local macOS recorder + transcriber. Pick your sources from the menu bar — computer audio, microphone, and optionally a window or a whole display — then record. Audio tracks stay separate so trailmix can transcribe them on-device into a speaker-tagged transcript. Nothing ever leaves the machine.

Named for what you eat on a long walk, and a nod to [Granola](https://www.granola.ai/), whose job it does without sending your meetings anywhere. One Swift executable, a menu-bar tray, no window.

**Requires:** macOS 15 or newer (ScreenCaptureKit's microphone output type and recording-to-file both landed in 15). Apple Silicon strongly recommended for transcription speed.

## Build and install

There are no downloads and no `.dmg`. You compile it, which takes one command and produces an ordinary `Trailmix.app` you can launch like anything else. No prior Swift or Mac development experience needed.

If you already have Xcode's command line tools, the whole thing is:

```sh
git clone <your-repo-url> trailmix
cd trailmix
make install
open ~/Applications/Trailmix.app
```

The long version follows, including one optional step that will save you a lot of irritation if you plan to rebuild more than once.

### 1. Get the Swift toolchain

Open Terminal (press ⌘-Space, type `Terminal`, hit return) and run:

```sh
swift --version
```

If that prints a version, move on. If the command isn't found, install Apple's command line tools:

```sh
xcode-select --install
```

A dialog appears; click **Install** and wait. It's a few GB and can take a while. If you already have Xcode from the App Store, you already have this.

### 2. Get the code

```sh
git clone <your-repo-url> trailmix
cd trailmix
```

Every command from here on assumes you're in that directory.

### 3. Make a signing certificate (optional, one time, 30 seconds)

Worth doing before your first build. macOS ties permissions like Screen Recording to an app's *code signature*, so an app signed with a stable certificate keeps its permissions across rebuilds. Without one, trailmix gets signed ad-hoc, macOS keys the grants to the exact bytes of the binary, and every single rebuild looks like a brand new app that has to be re-approved.

Open **Keychain Access** (⌘-Space, type it, return), then from the menu bar choose **Keychain Access › Certificate Assistant › Create a Certificate**:

| Field | Value |
|---|---|
| Name | `Trailmix` |
| Identity Type | Self Signed Root |
| Certificate Type | Code Signing |

Click **Create**, then **Continue** past the warning that the certificate is self-signed. Self-signed is the intent: it never leaves your Mac and it isn't claiming to be anyone.

Skipping this is fine if you're building once and never touching it again. The build tells you which way it signed.

### 4. Build and install

```sh
make install
```

That compiles the app, signs it, quits any running copy, and puts `Trailmix.app` in **`~/Applications`** (the Applications folder inside your home directory).

Why there and not `/Applications`: the system-wide folder is owned by root and only admin accounts can write to it. `~/Applications` works for every account, and Finder, Spotlight, and Launchpad treat it identically. If you *are* an admin and want it system-wide:

```sh
make install INSTALL_DIR=/Applications
```

The first build downloads two dependencies and compiles a few hundred files, so expect **two to five minutes** and a lot of scrolling output. Later builds take seconds. Two bits of output are normal and not your problem: a warning mentioning `fluidaudio` and unhandled files, which comes from a dependency, and a line telling you how the app was signed.

To skip installing entirely, run `make app`. That leaves the finished bundle at `dist/Trailmix.app` for you to drag wherever you want in Finder.

### 5. First launch and permissions

Double-click **Trailmix** in `~/Applications`, or run `open ~/Applications/Trailmix.app`. A small mountain icon appears in your menu bar. There is no Dock icon, no window, and no entry in ⌘-Tab: the menu bar *is* the app. Quit it with *Quit trailmix* in that menu.

Gatekeeper won't block it. Software you compiled yourself isn't quarantined the way a download is, so there's no "unidentified developer" wall to get past.

The first time you record, macOS asks for permission:

- **Screen Recording** is required for *every* recording, even audio-only. Approve it, then **quit and relaunch trailmix**. macOS does not apply this permission to an already-running process.
- **Microphone** is asked for separately, and only if the microphone source is switched on.

Both are attributed to Trailmix itself and show up under that name in System Settings › Privacy & Security.

To see what's actually granted at any point:

```sh
make doctor
```

### 6. Start at login (optional)

Click the mountain icon and tick **Start at login**. Untick it to undo. You can also revoke it from System Settings › General › Login Items, and the menu will notice next time you open it.

### Updating later

```sh
cd trailmix
git pull
make install
```

`make install` quits the running copy for you, so the build you just made is the one that launches next.

### If something goes wrong

| What you see | What it means |
|---|---|
| `swift: command not found` | Step 1 didn't finish. Run `xcode-select --install` again. |
| `make: command not found` | Same fix. `make` ships with the command line tools. |
| `error: ... requires macOS 15` | You're on an older macOS. This can't run there. |
| Permissions get re-asked after every rebuild | The app is ad-hoc signed. Do step 3, then `make install` again. |
| Recordings are silent or empty | Screen Recording permission. Run `make doctor`, grant it, then relaunch. |
| Menu bar icon never appears | Something failed at startup. Run `make run` to see the error on a terminal, or read `~/Library/Logs/trailmix.log`. |
| Anything else misbehaving | `tail -f ~/Library/Logs/trailmix.log`. Launched from Finder there's no terminal to print to, so that file is where every warning goes. |
| *Start at login* is greyed out | You're running the bare executable from `.build` rather than the app bundle. |
| `cp: /Applications/Trailmix.app: Permission denied` | You overrode `INSTALL_DIR` to `/Applications` without an admin account. Drop the override and use `~/Applications`. |
| `could not build module 'Darwin'`, or errors mentioning a module cache path | You moved or renamed the project folder. Run `rm -rf .build` and build again. |

## How to use

1. **Launch Trailmix** from `~/Applications`, or let it start at login.
2. **Click the mountain icon → pick your sources.** *Sources* toggles computer audio and microphone independently. *Capture* selects a display, a window, or None for audio only. The window list is built when you open the submenu. *Change recordings folder…* moves where new sessions land.
3. **Start recording.** First use prompts for Screen Recording and, if the mic is on, Microphone. The icon turns red with a running elapsed counter, and macOS shows the purple recording indicator. When you're capturing a window or a display, a red outline marks exactly what's in frame — it's click-through, follows the window around, and never ends up in the video.
4. **Stop recording.** The menu shows `finishing…` while the video file is closed, then returns to `idle`. Transcription starts automatically when there's audio (the menu shows progress); a notification fires when the transcript is ready. The first transcription after launch loads ~440 MB of model and can take a minute before anything appears.

Sources can't be changed mid-recording. ScreenCaptureKit tears down the recording if the stream configuration changes, so the menu locks those controls while capture is live.

Each session lands in `~/Trailmix/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `screen.mov` | the captured window or display, with audio muxed in (HEVC) |
| `mic.caf` | your side (default input device, AAC mono) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets, which sources were on |
| `transcript.json` | canonical transcript — engine provenance + timed, source-tagged (`mic` / `system`) segments |
| `transcript.md.txt` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Only the files for enabled sources are written. The audio in `screen.mov` is there so the video plays standalone; the `.caf` tracks are what get transcribed, because two separate tracks are what make `mic` vs `system` work. Both come from a single capture, so nothing is recorded twice.

Two tracks on purpose: speech models do better on clean single-source audio, and mic-vs-system is free two-party diarization — `mic` vs `system` with no speaker-identification model. The transcript labels the *source*, not the person: with no echo cancellation the mic hears your speakers too, so a `Mic` line is regularly the other side of the call. Headphones fix it. CAF on purpose: unlike m4a, it needs no finalization pass — if the process dies mid-meeting, everything already written is still readable.

`screen.mov` does *not* get that guarantee. MOV requires a finalization pass, so a `kill -9`, a panic, or a power loss leaves an unplayable video even though the audio tracks beside it survive intact. Quitting normally, or any signal trailmix can catch, finalizes it correctly.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2** (English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models (~440 MB) download once into `~/Library/Application Support/FluidAudio/Models/`, outside the app bundle, so they survive reinstalls and only ever download once per machine.

The download happens on first transcription unless you ask for it sooner. When the weights aren't cached, the menu grows a **Download transcription model** row that fetches them on demand and disappears once they land; `make doctor` reports the same thing from the terminal. Either way you are never downloading 440 MB immediately after an important meeting.

Each track is transcribed separately, shifted by its start offset so both share one clock, and merged by timestamp. Jobs run in a serial queue — you can start a new recording while the last one transcribes. Unfinished jobs resume on next launch (the filesystem is the queue: a session with `meta.json` but no `transcript.json` is pending). Failures append to the session's `transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/trailmix/config.json`:

```json
{
  "recordings_dir": "~/Trailmix",
  "sources": { "computer_audio": true, "microphone": true },
  "capture": { "mode": "none", "display_id": null, "fps": 30, "codec": "hevc" },
  "transcription": { "enabled": true, "engine": "parakeet" },
  "on_stop": "my-hook"
}
```

Parsed once at startup. Menu selections are written back here, preserving any keys you've hand-edited.

- `recordings_dir` — where sessions land. Resolution order: `--out` flag > config > `~/Trailmix`. *Change recordings folder…* in the menu writes this for you; existing recordings stay where they are.
- `sources` — which audio to record. Both default on. The menu writes these.
- `capture.mode` — `none` or `display`. A window selection is deliberately never persisted: `CGWindowID` isn't stable across launches, so a saved window target would silently point at something else. Windows reset to `none` on start.
- `capture.display_id` — `CGDirectDisplayID` to capture. A saved ID that's no longer attached falls back to audio only.
- `capture.fps` / `capture.codec` — `30` and `"hevc"` by default. `"h264"` is the other codec; trailmix checks what the system actually offers and falls back if the preferred one is unavailable.
- `transcription.enabled` — set `false` to just record.
- `on_stop` — shell command spawned with the session directory as its argument, **after the transcript is written** (or right after recording if transcription is disabled, or if there was no audio to transcribe). Wire it to whatever comes next: summarization, filing, indexing.

## Development

```sh
make app             # build + sign dist/Trailmix.app
make install         # ...and copy it to ~/Applications, quitting any running copy
make uninstall       # remove the installed copy
make doctor          # permissions, recordings folder, models
make run OUT=<dir>   # foreground daemon against a scratch recordings root
make icon            # regenerate AppIcon.icns from the ridge mark
make clean
```

The executable inside the bundle still takes subcommands, which is what `make run` and `make doctor` are wrapping:

```sh
~/Applications/Trailmix.app/Contents/MacOS/trailmix doctor
~/Applications/Trailmix.app/Contents/MacOS/trailmix run --out /tmp/scratch
```

Always run the copy *inside a bundle*, never `.build/release/trailmix`. The bare executable carries no `Info.plist`, so it has no microphone usage string, and macOS kills the process the moment it asks for the mic.

Signing uses a keychain identity named `Trailmix` when one exists and falls back to ad-hoc otherwise, warning you either way. The name is matched as a substring, so keep only one such identity in the keychain or `codesign` will call it ambiguous and refuse. Override it with `make app SIGN_ID="Developer ID Application: ..."`.

The app icon is generated, not checked in. `Scripts/make-icon.swift` renders the `.iconset` from the same ridge coordinates `MenuBarController` draws in the menu bar, at every size natively rather than downscaling one master, so the two marks can't drift apart.

## Stack

- **Swift** — single SPM executable target
- **ScreenCaptureKit** — one `SCStream` feeds all three tracks: an `SCRecordingOutput` writes `screen.mov`, while `.audio` and `.microphone` stream outputs are written separately. One capture, one timebase, so the video and both audio tracks share a clock.
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- Computer audio is captured globally: *everything* the Mac plays, including notification dings and music. Don't play Spotify during meetings.
- **Screen Recording permission is required for every recording**, even audio only. `SCStream` always needs a content filter, so audio-only capture still attaches to a display. `make doctor` reports the real grant state without prompting.
- **No echo cancellation.** ScreenCaptureKit's microphone capture is raw, with no equivalent to `AVAudioEngine`'s voice processing. Recording through speakers means the other side bleeds into your mic track and gets transcribed twice, once as `them` and once as `me`. Use headphones.
- Parakeet v2 is English-only. Other languages will come with the Whisper engine.
- Permissions are keyed to the code signature. Ad-hoc signing keys them to the binary's hash, so every rebuild looks like a different app to macOS and re-prompts. A stable certificate (build step 3) fixes that.
- The app is `LSUIElement`, so it has no Dock icon and doesn't appear in ⌘-Tab. The menu bar is the only place it exists while running.
- arm64 only. The bundle isn't a universal binary, since Parakeet wants the Neural Engine anyway.


