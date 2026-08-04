# trailmix

A minimal, fully local macOS recorder + transcriber. Pick your sources from the menu bar — computer audio, microphone, and optionally a window or a whole display — then record. Audio tracks stay separate so trailmix can transcribe them on-device into a source-tagged transcript. Nothing ever leaves the machine.

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

Open System Settings › General › Login Items, click **+**, and pick Trailmix from `~/Applications`. There is no menu row for this: launching trailmix is a double-click, and a login item is a preference rather than a control worth a permanent row in a small menu.

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
| Transcript has no *Mic* lines, or `mic.caf` is the right length but silent | Run `~/Applications/Trailmix.app/Contents/MacOS/trailmix mic --seconds 3`. It reports the real microphone format and signal level. |
| Anything else misbehaving | `tail -f ~/Library/Logs/trailmix.log`. Launched from Finder there's no terminal to print to, so that file is where every warning goes. |
| `cp: /Applications/Trailmix.app: Permission denied` | You overrode `INSTALL_DIR` to `/Applications` without an admin account. Drop the override and use `~/Applications`. |
| `could not build module 'Darwin'`, or errors mentioning a module cache path | You moved or renamed the project folder. Run `rm -rf .build` and build again. |

## How to use

1. **Launch Trailmix** from `~/Applications`, or let it start at login.
2. **Click the mountain icon → pick your sources.** *Computer audio* and *Microphone* toggle independently. *Video Capture* selects a display, a window, or None for audio only; the window list is built when you open the submenu. *Change recordings folder…* moves where new sessions land.
3. **Start recording.** First use prompts for Screen Recording and, if the mic is on, Microphone. The menu-bar mountain inverts — the ridge knocked out of a filled red slab — and the menu shows a running elapsed counter. macOS shows its own purple recording indicator too. When you're capturing a window or a display, a red outline marks exactly what's in frame — it's click-through and follows the window around.
4. **Stop recording.** The menu shows *Finishing…* while the files are closed, then returns to *Idle*. Transcription starts automatically when there's audio (the menu shows progress); a notification fires when the transcript is ready, and clicking it opens the session folder. The first transcription after launch loads ~440 MB of model and can take a minute before anything appears.

Sources can't be changed mid-recording. ScreenCaptureKit tears down the recording if the stream configuration changes, so the menu locks those controls while capture is live.

Each session lands in `~/Trailmix/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | the microphone, on its own (default input device, AAC mono, echo-cancelled) |
| `system.caf` | everything the Mac played, on its own (AAC stereo) |
| `mixed.m4a` | both audio sources in one file, playable anywhere |
| `mixed.mp4` | the captured window or display, with that same mixed audio (HEVC) |
| `transcript.md.txt` | the transcript, rendered for reading |
| `transcript.json` | the same transcript as data — engine provenance, timings, `mic` / `system` tags |
| `transcript.log` | what happened during transcription, including anything that went wrong |
| `meta.json` | start/end timestamps, duration, per-track start offsets, which sources were on |

Only the files for enabled sources are written.

The two `.caf` files are the raw capture, one per source, and they are what gets transcribed — two separate tracks are what make `Mic` vs `System` work without a speaker-identification model. Note the transcript labels the *source*, not the person: your mic can pick up the other side of a call, so a `Mic` line is not a guarantee that you said it.

The two `mixed.*` files are the ones to send someone. Both contain every audio source the session captured; one of them has pictures. They're built after the recording stops, so they appear a moment after the rest.

CAF and MP4 behave differently if trailmix dies mid-recording. CAF needs no finalization pass, so everything already written to `mic.caf` and `system.caf` stays readable through a `kill -9`, a panic, or a power loss. `mixed.mp4` does need one, and without it the video won't open. Quitting normally, or any signal trailmix can catch, finalizes it correctly.

mp4 rather than mov because the point of that file is that someone can open it. That's only half a promise, though — HEVC inside mp4 still needs a codec Windows doesn't always ship, so set `"codec": "h264"` if playing anywhere matters more than halving the file size.

### What "computer audio" actually captures

ScreenCaptureKit scopes audio at the **application** level, never at the window level, and the *Video Capture* setting decides which apps that means. It reads like a video setting; it isn't only one.

| Video Capture | Video | `system.caf` contains |
|---|---|---|
| None (audio only) | nothing | every app on the machine |
| A display | that display | every app on the machine |
| A window | just that window | **only that window's app** |

The first two take the whole system mix. Audio-only still attaches to a display behind the scenes, because ScreenCaptureKit demands a content filter even when you want no video, and that filter takes everything.

The window case is the one to watch. Capture a Firefox window and you get audio from every Firefox tab and window, including ones not on screen — but nothing from Zoom, Slack, or Music. Usually that's what you want: record the Zoom window, get Zoom's audio. But capture the wrong window during a call and `system.caf` is silent, with nothing anywhere to tell you why. If in doubt, use *None* or a display.

trailmix's own sounds are never recorded, whichever mode you're in.

The red capture outline is excluded from the recording the same way. That's reliable for a window (the capture contains only that window) but relies on macOS listing trailmix as a shareable application when capturing a whole display, which it doesn't always do. If you spot the outline burned into a display recording, that's why — `~/Library/Logs/trailmix.log` says so explicitly when it happens.

### Echo

Play something through your speakers while the mic is on and, physically, the mic hears it. Left alone that means the far side of a call is recorded twice — once in `system.caf`, once bleeding into `mic.caf` a beat later — and the transcript says everything twice.

trailmix takes the microphone off ScreenCaptureKit and runs it through the macOS voice-processing unit instead, which subtracts the system output from the mic signal. That is the only route to echo cancellation on macOS; ScreenCaptureKit hands over the raw input and offers nothing to ask for.

Voice processing is a bundle, though. Echo cancellation arrives with automatic gain control and noise suppression, so the mic sounds processed compared with a raw capture — usually an improvement for speech, occasionally not for anything else. `"echo_cancellation": false` puts the mic back on ScreenCaptureKit, raw. Headphones sidestep the whole question either way.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2** (English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models (~440 MB) download once into `~/Library/Application Support/FluidAudio/Models/`, outside the app bundle, so they survive reinstalls and only ever download once per machine.

The download happens on first transcription unless you ask for it sooner. When the weights aren't cached, the menu grows a **Download transcription model** row that fetches them on demand and disappears once they land; `make doctor` reports the same thing from the terminal. Either way you are never downloading 440 MB immediately after an important meeting.

Each track is transcribed separately, shifted by its start offset so both share one clock, and merged by timestamp. Jobs run in a serial queue — you can start a new recording while the last one transcribes. Unfinished jobs resume on next launch (the filesystem is the queue: a session with `meta.json` but no `transcript.json` is pending). Failures append to the session's `transcript.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/trailmix/config.json`:

```json
{
  "recordings_dir": "~/Trailmix",
  "sources": { "computer_audio": true, "microphone": true },
  "capture": { "mode": "none", "display_id": null, "fps": 30, "codec": "hevc" },
  "transcription": { "enabled": true, "engine": "parakeet" },
  "echo_cancellation": true,
  "on_stop": "my-hook"
}
```

Parsed once at startup. Menu selections are written back here, preserving any keys you've hand-edited.

- `recordings_dir` — where sessions land. Resolution order: `--out` flag > config > `~/Trailmix`. *Change recordings folder…* in the menu writes this for you; existing recordings stay where they are.
- `sources` — which audio to record. Both default on. The menu writes these.
- `capture.mode` — `none` or `display`. A window selection is deliberately never persisted: `CGWindowID` isn't stable across launches, so a saved window target would silently point at something else. Windows reset to `none` on start.
- `capture.display_id` — `CGDirectDisplayID` to capture. A saved ID that's no longer attached falls back to audio only.
- `capture.fps` / `capture.codec` — `30` and `"hevc"` by default. `"h264"` is the other codec, and the one to pick if the video needs to play on machines that may not have HEVC. trailmix checks what the system actually offers and falls back if the preferred one is unavailable.
- `echo_cancellation` — on by default. Routes the microphone through the macOS voice-processing unit so audio coming out of your speakers doesn't also land in the mic track. Set `false` to record the mic raw, straight off ScreenCaptureKit, exactly as it arrives.
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

The executable inside the bundle takes subcommands, which is what `make run` and `make doctor` are wrapping:

```sh
~/Applications/Trailmix.app/Contents/MacOS/trailmix doctor
~/Applications/Trailmix.app/Contents/MacOS/trailmix run --out /tmp/scratch
~/Applications/Trailmix.app/Contents/MacOS/trailmix mic
```

Always run the copy *inside a bundle*, never `.build/release/trailmix`. The bare executable carries no `Info.plist`, so it has no microphone usage string, and macOS kills the process the moment it asks for the mic.

Signing uses a keychain identity named `Trailmix` when one exists and falls back to ad-hoc otherwise, warning you either way. The name is matched as a substring, so keep only one such identity in the keychain or `codesign` will call it ambiguous and refuse. Override it with `make app SIGN_ID="Developer ID Application: ..."`.

The app icon is generated, not checked in. `Scripts/make-icon.swift` renders the `.iconset` from the same ridge coordinates `MenuBarController` draws in the menu bar, at every size natively rather than downscaling one master, so the two marks can't drift apart.

### Diagnostics

Launched from Finder or at login there is no terminal attached, so everything the daemon would print goes to **`~/Library/Logs/trailmix.log`** as well. That file is the first place to look when a recording comes out wrong — it records what each capture started with, what it wrote, and every warning along the way. `tail -f` it while you record. (It's mirrored to the unified log too, under subsystem `io.github.stephenturner.trailmix`, but `log stream` needs an admin account.)

**`trailmix mic`** reports what the microphone is really doing, which is worth more than it sounds: the failure mode for audio capture is a file of the right length full of silence, not a crash.

```sh
trailmix mic                      # device, formats, per-channel levels
trailmix mic --raw                # skip voice processing, for comparison
trailmix mic --write /tmp/t.caf   # record through the real writer and decode it back
```

It prints the default input device, the format before and after voice processing, the format the tap *actually* delivers, and peak/RMS per channel. If the peak is near zero while you're talking, the capture path is broken regardless of what the file size suggests.

## Stack

- **Swift** — single SPM executable target, no dependencies beyond FluidAudio and swift-argument-parser
- **ScreenCaptureKit** — screen capture and system audio. An `SCRecordingOutput` writes the video while an `.audio` stream output writes `system.caf` separately, from the same capture.
- **AVAudioEngine** — the microphone, on its own, so macOS voice processing can cancel the echo. ScreenCaptureKit has no equivalent.
- **AVAudioFile** — streaming AAC encode into CAF
- **AVFoundation** — the post-recording mix and remux, both passthrough where possible so nothing is re-encoded
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- Computer audio is captured per *application*, and which applications depends on the *Video Capture* setting — see [What "computer audio" actually captures](#what-computer-audio-actually-captures). With None or a display selected it really is everything the Mac plays, notification dings and music included.
- **Screen Recording permission is required for every recording**, even audio only. `SCStream` always needs a content filter, so audio-only capture still attaches to a display. `make doctor` reports the real grant state without prompting.
- Echo cancellation brings automatic gain control and noise suppression with it, and ducks other audio slightly while recording. Both are macOS behaviours that cannot be separated from it. `"echo_cancellation": false` or headphones if that matters.
- `mixed.m4a` and the audio inside `mixed.mp4` are built *after* the recording stops, so they appear a moment later than the other files. A crash in that window leaves the raw tracks intact but no mixed versions, and nothing regenerates them.
- Parakeet v2 is English-only. Other languages will come with the Whisper engine.
- Permissions are keyed to the code signature. Ad-hoc signing keys them to the binary's hash, so every rebuild looks like a different app to macOS and re-prompts. A stable certificate (build step 3) fixes that.
- The app is `LSUIElement`, so it has no Dock icon and doesn't appear in ⌘-Tab. The menu bar is the only place it exists while running.
- arm64 only. The bundle isn't a universal binary, since Parakeet wants the Neural Engine anyway.
