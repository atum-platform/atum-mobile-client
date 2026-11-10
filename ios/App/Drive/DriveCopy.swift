import Foundation
import AtumDrive

/// Drive reuses the pinned desktop vocabulary wherever it says the same thing.
/// Phone-only Stage A words are the exact committed atum-app export fragment;
/// the repository-wide design pin moves after that producer branch merges.
@MainActor
struct DriveCopy {
    private static let root = "src.matrix.drive-copy.matrixDriveCopy."
    private static let stageA = try! DriveStageACopy()
    private let design: LiveDesign

    init(design: LiveDesign) { self.design = design }

    private func text(_ suffix: String) -> String { design.text(Self.root + suffix) }
    private func exported(_ key: String) -> String {
        do { return try Self.stageA.text(key, locale: design.locale) }
        catch { preconditionFailure("Invalid exported Drive copy key: \(key)") }
    }

    var title: String { text("title") }
    var connect: String { text("turnOn") }
    var connectTitle: String { text("signIn.title") }
    var connectBody: String { exported("connectBody") }
    var signInAgain: String { text("signInAgain") }
    var signInProblem: String { text("problem.sign_in") }
    var empty: String { text("empty") }
    var refresh: String { text("refresh") }
    var refreshing: String { text("refreshing") }
    var retry: String { text("retry") }
    var stale: String { text("facts.stale") }
    var offline: String { text("problem.network") }
    var provisioning: String { text("problem.setting_up") }
    var denied: String { text("problem.not_allowed") }
    var failed: String { text("failed") }
    var keepOffline: String { exported("keepOffline") }
    var removeOffline: String { exported("removeOffline") }
    var keptOffline: String { exported("keptOffline") }
    var needsConnection: String { exported("needsConnection") }
    var lowDisk: String { exported("lowDisk") }
    var downloadFailed: String { exported("downloadFailed") }
    var changed: String { exported("changed") }
    var storageUnavailable: String { exported("storageUnavailable") }
    var serverQuota: String { text("facts.issues.drive_full.title") }
    var more: String { text("more") }
    var cancel: String { text("cancel") }
    var dismiss: String { design.text("src.matrix.chat-copy.copies.dismiss") }
    var unavailable: String { text("status.error") }
    var truncated: String { text("truncated") }
    var emptyRootTitle: String { text("emptyRoot.title") }
    /// The desktop's root body says to drop files into the Mac's Drive folder;
    /// the phone only reads Drive, so it says where the files will come from.
    var emptyRootBody: String { text("comingSoonHelp") }
    var upToDate: String { text("status.ready") }
    var recents: String { owed("browser.recents", Self.recentsFallback) }
    var allFiles: String { owed("browser.allFiles", Self.allFilesFallback) }

    /// "Up to date · 14:32", as the desktop's Drive status line.
    func upToDate(at: Date, now: Date = Date()) -> String {
        upToDate + " · " + DriveTimeFormat.syncTime(at, now: now, locale: Locale(identifier: design.locale))
    }

    /// Desktop Drive keys the pinned export does not carry yet
    /// (`matrixDriveCopy.browser.*`, atum-app 050ede8edf5). The export wins once
    /// it carries them; until then, the desktop's own five-locale words.
    private func owed(_ suffix: String, _ fallback: [String: String]) -> String {
        let key = Self.root + suffix
        if design.copy.contains(key) { return design.text(key) }
        return fallback[AccountSettingsText.normalizedLocale(design.locale)] ?? fallback["en"]!
    }

    static let recentsFallback = ["en": "Recents", "vi": "Gần đây", "ja": "最近使った項目",
                                  "zh": "最近使用", "zh-hant": "最近使用"]
    static let allFilesFallback = ["en": "All files", "vi": "Tất cả tệp", "ja": "すべてのファイル",
                                   "zh": "所有文件", "zh-hant": "所有檔案"]

    func notice(_ notice: DriveNotice) -> String {
        switch notice {
        case .needsConnection: needsConnection
        case .downloadFailed: downloadFailed
        case .lowDisk: lowDisk
        case .serverQuota: serverQuota
        case .denied: denied
        case .changed: changed
        case .storageUnavailable: storageUnavailable
        }
    }
}
