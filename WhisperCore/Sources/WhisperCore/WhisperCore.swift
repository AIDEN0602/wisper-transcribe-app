import Foundation
import WhisperKit

/// Build probe: verifies that WhisperKit compiles and links with the
/// Command Line Tools toolchain. Real API surface comes next.
public enum WhisperCoreInfo {
    public static let version = "0.1.0"

    /// Returns the WhisperKit type name to force the linker to pull the dependency in.
    public static func whisperKitAvailable() -> String {
        String(describing: WhisperKit.self)
    }
}
