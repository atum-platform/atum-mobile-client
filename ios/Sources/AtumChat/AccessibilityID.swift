/// Accessibility identifiers the UI tests rely on (plan §2.10). Frozen in
/// S0: views and `AtumMobileUITests` both read them from here.
public enum AccessibilityID {
    /// The transcript scroll view. Its accessibility value is `following`
    /// or `detached:N` (`transcriptValue(_:)`).
    public static let transcript = "transcript"
    /// The newest event row. An element has one identifier, so the newest
    /// row carries this one instead of `row.<id>`, and takes `row.<id>` as
    /// soon as a newer event row arrives. A test that follows one row across
    /// an append (the sent message once the answer lands) queries it by
    /// `row.<id>` (scripted scenarios use fixed IDs) or by its text.
    public static let rowLatest = "row.latest"
    /// The typing row.
    public static let rowTyping = "row.typing"
    /// The one live working line under the typing bubble (agent-turns/1.4).
    public static let rowWorking = "row.working"
    public static let composerField = "composer.field"
    public static let composerSend = "composer.send"
    /// The dictation mic in the controls row (value `recording` while live).
    public static let composerMic = "composer.mic"
    /// The model chip in an assistant chat's controls row.
    public static let composerModel = "composer.model"
    /// The inline line shown when dictation cannot start.
    public static let composerDictationRefusal = "composer.dictation.refusal"
    public static let pillLatest = "pill.latest"
    /// The actionable failed-delivery mark. Frozen for S1 U5 and S4 upload
    /// failures; views must not own a second literal.
    public static let sendFailed = "send.failed"
    public static let sendRetry = "send.retry"
    public static let sendDelete = "send.delete"
    /// The empty-chat display line. Frozen for U10 and the S6 display role.
    public static let chatGreeting = "chat.greeting"
    public static let mediaAdd = "media.add"
    public static let mediaTray = "media.tray"
    public static let mediaRefusal = "media.refusal"
    public static let mediaViewer = "media.viewer"
    public static let mediaViewerPhoto = "media.viewer.photo"
    public static let mediaShare = "media.share"
    public static let appBotHero = "appbot.hero"
    public static let appBotContinueSheet = "appbot.continueSheet"
    public static let appBotRoomRetry = "appbot.room.retry"

    /// `row.<displayId>` for any other row.
    public static func row(id: String) -> String { "row." + id }

    public static func noticeAction(id: String) -> String { "notice.action." + id }
    public static func mediaAttachment(id: String) -> String { "media.attachment." + id }
    public static func mediaRemove(id: String) -> String { "media.remove." + id }
    public static func mediaImage(id: String) -> String { "media.image." + id }
    public static func mediaFile(id: String) -> String { "media.file." + id }

    public static func row(_ row: ChatRow) -> String {
        if case .typing = row.item.kind { return rowTyping }
        if row.item.isProgressLine { return rowWorking }
        return row.isLatest ? rowLatest : self.row(id: row.id)
    }

    public static func transcriptValue(_ state: FollowState) -> String {
        switch state {
        case .following: return "following"
        case let .detached(count): return "detached:\(count)"
        }
    }
}
