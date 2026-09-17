import Foundation
import WhisperKit

/// Whisper model choices exposed to the apps, ordered small → large.
///
/// Raw values are WhisperKit model names from the
/// `argmaxinc/whisperkit-coreml` HuggingFace repo.
public enum WhisperModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case tiny = "tiny"
    case base = "base"
    case smallEnglish = "small.en"
    case small = "small"
    case largeTurbo = "large-v3-v20240930_turbo"
    case large = "large-v3"

    public var id: String { rawValue }

    /// Short human-readable label for pickers.
    public var displayName: String {
        switch self {
        case .tiny: return "Tiny (fastest)"
        case .base: return "Base"
        case .smallEnglish: return "Small (English only)"
        case .small: return "Small"
        case .largeTurbo: return "Large v3 Turbo (recommended)"
        case .large: return "Large v3 (most accurate)"
        }
    }

    /// Approximate download size, for showing before download.
    public var approximateDownloadMB: Int {
        switch self {
        case .tiny: return 150
        case .base: return 290
        case .smallEnglish, .small: return 970
        case .largeTurbo: return 1700
        case .large: return 3100
        }
    }

    /// Sensible default for the current machine class.
    public static var recommended: WhisperModel { .largeTurbo }
}

public enum ModelCatalog {
    /// Where downloaded models live on disk, shared by all our apps on this device.
    public static func defaultModelFolder() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhisperApps/Models", isDirectory: true)
    }

    /// Where a specific model variant is unpacked inside `folder`.
    public static func variantFolder(_ model: WhisperModel, folder: URL? = nil) -> URL {
        (folder ?? defaultModelFolder())
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(model.rawValue)", isDirectory: true)
    }

    /// CoreML bundles WhisperKit needs before a model can be loaded at all.
    private static let requiredComponents = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// True only if every required CoreML bundle is present *with its
    /// weights*.
    ///
    /// A directory-exists check is not enough: an interrupted HuggingFace
    /// download leaves the `.mlmodelc` folders behind holding nothing but
    /// `analytics/coremldata.bin`, while the real weights sit in the hub
    /// cache as `.incomplete` files. That state used to read as
    /// "downloaded", so the app skipped the download and then failed to
    /// load the model on every single recording.
    public static func isDownloaded(_ model: WhisperModel, folder: URL? = nil) -> Bool {
        let modelDir = variantFolder(model, folder: folder)
        let fm = FileManager.default
        for component in requiredComponents {
            let bundle = modelDir.appendingPathComponent(component, isDirectory: true)
            guard fm.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path),
                  let weights = try? bundle
                      .appendingPathComponent("weights/weight.bin")
                      .resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  weights > 0
            else { return false }
        }
        return true
    }

    /// Deletes a partial/corrupt download — both the unpacked variant folder
    /// and the hub cache holding its `.incomplete` chunks — so the next
    /// `prepare()` starts a clean download instead of resuming into the
    /// same broken state.
    public static func removeDownload(_ model: WhisperModel, folder: URL? = nil) {
        let root = folder ?? defaultModelFolder()
        let fm = FileManager.default
        try? fm.removeItem(at: variantFolder(model, folder: root))
        let cache = root
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download",
                                    isDirectory: true)
            .appendingPathComponent("openai_whisper-\(model.rawValue)", isDirectory: true)
        try? fm.removeItem(at: cache)
    }
}
