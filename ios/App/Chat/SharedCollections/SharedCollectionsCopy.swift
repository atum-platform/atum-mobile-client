import AtumChat
import AtumDesign
import Foundation

/// Every word the Shared section says. The desktop panel's table
/// (`person-info-copy.ts`, `src.matrix.person-info-copy.copy.*`) is pinned
/// only in part (63e122d3a2: loading, failed, tryAgain, back, …). Its shared-
/// section keys are not exported yet (`docs/ports/shared-collections-ui.md`):
/// each is read only after `design.copy.contains` finds it; until then an
/// exported key with the nearest meaning stands in, or the line is left out.
/// No word is written in Swift.
@MainActor
struct SharedCollectionsCopy {
    let design: LiveDesign

    /// Desktop keys held back from the phone export (tests/test_copy_keys_in_pin.py PENDING).
    private enum Pending: String {
        case media = "src.matrix.person-info-copy.copy.media"
        case files = "src.matrix.person-info-copy.copy.files"
        case links = "src.matrix.person-info-copy.copy.links"
        case seeAll = "src.matrix.person-info-copy.copy.seeAll"
        case seeAllMedia = "src.matrix.person-info-copy.copy.seeAllMedia"
        case seeAllFiles = "src.matrix.person-info-copy.copy.seeAllFiles"
        case seeAllLinks = "src.matrix.person-info-copy.copy.seeAllLinks"
        case loadMore = "src.matrix.person-info-copy.copy.loadMore"
        case noMedia = "src.matrix.person-info-copy.copy.noMedia"
        case noFiles = "src.matrix.person-info-copy.copy.noFiles"
        case noLinks = "src.matrix.person-info-copy.copy.noLinks"
        case noneRecent = "src.matrix.person-info-copy.copy.noneRecent"
    }

    private func pending(_ key: Pending) -> String? {
        design.copy.contains(key.rawValue) ? design.text(key.rawValue) : nil
    }

    /// Section title (and the See all page's title).
    func title(_ section: SharedCollectionSection) -> String {
        switch section {
        case .media: pending(.media) ?? chat(.photo)
        case .files: pending(.files) ?? design.text("desktop.atum.workspace.tabFiles")
        case .links: pending(.links) ?? design.text("shared.matrix-debug-share-copy.matrixDebugShareCopy.open")
        }
    }

    var seeAll: String { pending(.seeAll) ?? more }

    /// VoiceOver's name for a section's See all: the desktop's own words,
    /// otherwise the visible label with the section title as its hint.
    func seeAllLabel(_ section: SharedCollectionSection) -> String {
        let key: Pending = switch section {
        case .media: .seeAllMedia
        case .files: .seeAllFiles
        case .links: .seeAllLinks
        }
        return pending(key) ?? seeAll
    }

    func hasOwnSeeAllLabel(_ section: SharedCollectionSection) -> Bool {
        let key: Pending = switch section {
        case .media: .seeAllMedia
        case .files: .seeAllFiles
        case .links: .seeAllLinks
        }
        return design.copy.contains(key.rawValue)
    }

    var loadMore: String { pending(.loadMore) ?? more }

    func empty(_ section: SharedCollectionSection) -> String {
        let key: Pending = switch section {
        case .media: .noMedia
        case .files: .noFiles
        case .links: .noLinks
        }
        return pending(key) ?? design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.rosterStatesEmptyText")
    }

    /// "None in recent messages…": no exported stand-in, so nothing until the
    /// desktop key is exported (Load more still says there is more to read).
    var noneRecent: String? { pending(.noneRecent) }

    var loading: String { design.text(PersonInfoKey.loading) }
    /// "Couldn’t load this." beside a Try again button, as on the desktop.
    var failed: String { design.text(PersonInfoKey.failed) }
    var tryAgain: String { design.text(PersonInfoKey.tryAgain) }
    var offline: String { design.text("desktop.atum.offline.banner") }
    var photo: String { chat(.photo) }
    var video: String { chat(.mediaKindVideo) }
    var openPhotoHint: String { chat(.mediaOpenPhotoHint) }
    var openFileHint: String { chat(.mediaOpenFileHint) }
    var share: String { chat(.mediaShare) }
    /// Save to Photos (the desktop's "Save"; no phone-specific line yet).
    var save: String { design.text("src.matrix.chat-copy.copies.save") }
    var saved: String { design.text("src.matrix.assistant-card.copy.assistantCardCopies.saved") }
    var error: String { chat(.errorGeneric) }
    var linkHeld: String { chat(.linkHeld) }
    var dismiss: String { chat(.dismiss) }
    var you: String { chat(.you) }

    func openLink(_ url: String) -> String {
        design.text("desktop.dm.resource.openAria", arguments: [.text(url)])
    }

    func kind(_ media: ChatMedia?, name: String?) -> String {
        chat((media?.presentationKind(fallbackFilename: name) ?? MediaKind(mimetype: nil, filename: name)).copyKey)
    }

    private var more: String { design.text("desktop.atum.agents.more") }

    private func chat(_ key: ChatCopyKey) -> String { ChatCopy.text(design, key) }
}
