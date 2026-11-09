import AtumDesign

/// The words of the composer mic, all from the atum-app export (no
/// Swift-authored sentences). Keys: `mobileDeviceCopy.dictation*`.
@MainActor
enum ComposerDictationCopy {
    static let start = "src.matrix.mobile-device-copy.mobileDeviceCopy.dictationStart"
    static let stop = "src.matrix.mobile-device-copy.mobileDeviceCopy.dictationStop"
    static let permissionDenied = "src.matrix.mobile-device-copy.mobileDeviceCopy.dictationPermissionDenied"
    static let unavailable = "src.matrix.mobile-device-copy.mobileDeviceCopy.dictationUnavailable"
    /// Not in the export yet (en "Listening", vi "Đang nghe"): spoken as the
    /// mic's value while recording once the key lands; nothing is said before.
    static let listening = "src.matrix.mobile-device-copy.mobileDeviceCopy.dictationListening"

    static func micLabel(_ design: LiveDesign, recording: Bool) -> String {
        design.text(recording ? stop : start)
    }

    static func micValue(_ design: LiveDesign, recording: Bool) -> String {
        guard recording, design.copy.contains(listening) else { return "" }
        return design.text(listening)
    }

    static func refusal(_ design: LiveDesign, _ refusal: ComposerDictation.Refusal) -> String {
        design.text(refusal == .permissionDenied ? permissionDenied : unavailable)
    }
}
