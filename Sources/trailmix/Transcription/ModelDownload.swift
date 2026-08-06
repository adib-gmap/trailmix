import FluidAudio
import Foundation

/// On-demand fetch of the parakeet weights, so the ~440 MB download happens
/// when the user asks for it rather than in the middle of the first
/// transcription after a meeting they cared about.
///
/// This is a convenience, not a prerequisite. `ParakeetEngine.prepare()` still
/// downloads the models itself if this never runs, and `AsrModels.download`
/// returns immediately when the files are already cached, so the two paths
/// compose without needing to know about each other.
@MainActor
final class ModelDownload {
    enum State: Equatable {
        /// Weights are in the cache; nothing to offer.
        case present
        /// Not downloaded, and no download running.
        case missing
        /// Download in flight. The payload is a user-facing progress line.
        case working(String)
        /// Last attempt failed. The payload is the underlying error, for the
        /// log and the notification, not for the menu.
        case failed(String)
    }

    private(set) var state: State = .missing
    /// Fired on the main actor whenever `state` actually changes. Repeated
    /// progress callbacks that resolve to the same line don't fire it, which
    /// is what keeps a chatty download from thrashing the menu.
    var onChange: ((State) -> Void)?

    private var task: Task<Void, Never>?

    /// Re-read the cache. Worth calling every time the menu opens: a
    /// transcription can populate the cache behind our back, and this is the
    /// only way the download row learns to disappear.
    func refresh() {
        guard task == nil else { return }
        apply(ParakeetModel.isPresent ? .present : .missing)
    }

    func start() {
        guard task == nil else { return }
        guard !ParakeetModel.isPresent else {
            apply(.present)
            return
        }

        apply(.working("Checking model files…"))
        // Progress lands on an unspecified queue, per FluidAudio's contract,
        // so it hops to the main actor before touching any of our state.
        let progress: ProgressHandler = { [weak self] progress in
            Task { @MainActor in self?.report(progress) }
        }
        task = Task { [weak self] in
            var failure: Error?
            do {
                try await AsrModels.download(
                    version: ParakeetModel.version,
                    progressHandler: progress
                )
            } catch {
                failure = error
            }
            self?.finish(failure)
        }
    }

    /// Turn a progress callback into a line of menu text.
    ///
    /// Deliberately no percentage. `AsrModels.download` runs one `ModelHub`
    /// operation per model file and `fractionCompleted` is documented as a
    /// fraction of *this* operation, so it restarts at zero for each file. A
    /// percentage built from it would climb to 100% and reset three more times,
    /// which is worse than no number at all.
    private func report(_ progress: DownloadProgress) {
        // A callback can land after the download already finished.
        guard task != nil else { return }
        let line: String
        switch progress.phase {
        case .listing:
            line = "Checking model files…"
        case .downloading:
            line = "Downloading model…"
        case .compiling(let name) where !name.isEmpty:
            line = "Compiling \(name)…"
        case .compiling:
            line = "Finishing…"
        }
        apply(.working(line))
    }

    /// Both outcomes are worth surfacing: the download is long enough that the
    /// user has probably stopped watching the menu by the time it lands.
    private func finish(_ error: Error?) {
        task = nil

        if let error {
            let message = error.localizedDescription
            Log.warn("model download failed: \(message)")
            notifyUser(title: "trailmix: model download failed", body: message)
            apply(.failed(message))
            return
        }

        // Trust the cache, not the return value: a download that reports
        // success but leaves the directory incomplete should leave the retry
        // button on screen rather than claim it worked.
        guard ParakeetModel.isPresent else {
            let message = "download completed but the model files are missing"
            Log.warn("model download failed: \(message)")
            notifyUser(title: "trailmix: model download failed", body: message)
            apply(.failed(message))
            return
        }

        Log.info("transcription model ready")
        notifyUser(
            title: "trailmix: transcription model ready",
            body: "recordings will now transcribe without downloading first"
        )
        apply(.present)
    }

    private func apply(_ new: State) {
        guard new != state else { return }
        state = new
        onChange?(new)
    }
}
