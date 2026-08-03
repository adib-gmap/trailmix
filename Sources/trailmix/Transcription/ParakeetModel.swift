import FluidAudio
import Foundation

/// The one place the parakeet model version is named.
///
/// Every FluidAudio model API defaults to `.v3`, so an omitted `version:`
/// argument silently targets a different ~600 MB download than the weights
/// `ParakeetEngine` actually loads — and the mistake is invisible, because the
/// engine then downloads v2 anyway on the first transcription. Routing the
/// engine, the doctor report, and the menu's download button through here means
/// they cannot disagree about which model they mean.
enum ParakeetModel {
    static let version: AsrModelVersion = .v2

    /// Roughly what the v2 Core ML weights occupy once unpacked. Shown to the
    /// user before they commit to the download, so approximate is fine.
    static let approximateSize = "440 MB"

    static var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    /// A handful of file-existence checks against the cache directory. Cheap
    /// enough to call every time the menu opens.
    static var isPresent: Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: version)
    }
}
