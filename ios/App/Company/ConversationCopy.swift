import AtumNativeAPI
import Foundation

/// Every word of Direct messages. The keys are not in the vendored export yet,
/// so they resolve from `ConversationPendingCopy` (the desktop's own values, five
/// locales); the shared words (Retry, Cancel, the plain-status refusals) come
/// from the export. Nothing is hand-edited into `ios/Vendor/AtumDesign`.
@MainActor
struct ConversationCopy {
    let design: LiveDesign

    private var locale: String { design.locale }

    func text(_ key: String) -> String {
        ConversationPendingCopy.tables[locale]?[key]
            ?? ConversationPendingCopy.tables["en"]?[key]
            ?? key
    }

    var directMessages: String { text("directMessages") }
    var newMessage: String { text("newMessage") }
    var newMessageHint: String { text("newMessageHint") }
    var nobody: String { text("newMessageNobody") }
    var noMatch: String { text("peopleNoMatch") }
    var start: String { text("newMessageStart") }
    var limit: String { text("newMessageLimit") }
    var note: String { text("conversationNote") }
    var readOnlyBanner: String { text("conversationReadOnlyBanner") }
    var readOnlyTag: String { text("conversationReadOnlyTag") }
    var settingUp: String { text("conversationSettingUp") }
    var hide: String { text("conversationHide") }
    var hidden: String { text("hiddenConversations") }
    var addNote: String { text("conversationAddNote") }
    var addConfirm: String { text("conversationAddConfirm") }
    var loading: String { text("conversationsLoading") }
    var failed: String { text("conversationsFailed") }
    var attachments: String { text("conversationAttachments") }
    var notReady: String { text("conversationNotReady") }
    var openFailed: String { text("conversationOpenFailed") }
    var menu: String { text("conversationMenu") }
    var none: String { text("conversationNone") }
    var addPeople: String { text("addPeopleTitle") }
    var searchPeople: String { text("addPeopleSearch") }

    func peopleSelected(_ count: Int) -> String { ConversationPendingCopy.peopleSelected(count, locale: locale) }
    func group(_ count: Int) -> String { ConversationPendingCopy.conversationGroup(count, locale: locale) }
    func open(_ name: String) -> String { ConversationPendingCopy.openConversation(name, locale: locale) }

    /// "Retry" in the export's own word.
    var retry: String { design.text("shared.matrix-company-copy.copy.retry") }
    var cancel: String { design.text("src.matrix.chat-copy.copies.cancel") }

    /// The line under a picker or the list after a refusal. The six typed
    /// reasons are the conversation family's; a plain status reuses the
    /// company words; a lost answer says the companies cannot be reached.
    func refusal(_ refusal: ConversationRefusal) -> String {
        let company = CompanyCopy(design: design)
        switch refusal {
        case .conversationUnavailable: return text("refusal.conversation_unavailable")
        case .participantUnavailable: return text("refusal.participant_unavailable")
        case .participantLimit: return text("refusal.participant_limit")
        case .participantSetConflict: return text("refusal.participant_set_conflict")
        case .admissionEpochConflict: return text("refusal.admission_epoch_conflict")
        case .readOnly: return text("refusal.conversation_read_only")
        case let .plain(plain):
            switch plain {
            case .invalid: return company.text(CompanyCopyKey("invalid"))
            case .authentication: return company.text(CompanyCopyKey("authentication"))
            case .denied: return company.text(CompanyCopyKey("denied"))
            case .missing: return company.text(CompanyCopyKey("missing"))
            case .conflict: return company.text(CompanyCopyKey("conflict"))
            case .limit: return company.text(CompanyCopyKey("limit"))
            case .unavailable: return company.text(CompanyCopyKey("unavailable"))
            }
        case .lost: return company.text(CompanyCopyKey("unavailable"))
        }
    }

    /// What VoiceOver says for a row: the opener, the platform's state, the mark.
    func rowLabel(_ row: ConversationListRow) -> String {
        var parts = [open(row.row.title)]
        if row.row.kind == .groupDM { parts.append(group(row.row.participantCount)) }
        switch row.row.state {
        case .readOnly: parts.append(readOnlyTag)
        case .settingUp: parts.append(settingUp)
        case .ready: break
        }
        parts += CompanyCopy(design: design).markDescription(row.badge)
        return parts.joined(separator: ", ")
    }
}

/// The Direct messages section's own rows: "You" (personal notes) and the
/// private Chief of Staff. Words the export already has come from it; the ones
/// it lacks read their proposed export key first and fall back to the closest
/// exported word until the copy worker's keys land (port note
/// `docs/ports/team-space-dms-cos.md`, PENDING-COPY). No literal is shown.
@MainActor
struct DirectMessagesCopy {
    let design: LiveDesign

    /// The key when the pinned export has it, else the fallback key's text.
    private func pending(_ key: String, fallback: String) -> String {
        design.copy.contains(key) ? design.text(key) : design.text(fallback)
    }

    /// "You", the row's name (desktop `team.you`).
    var you: String { design.text("desktop.dm.you") }

    /// VoiceOver's name for the row (desktop `team.personalNotes`, "Your personal notes").
    var personalNotes: String {
        // PENDING-COPY:shared.matrix-team-space-copy.copy.personalNotes
        pending("shared.matrix-team-space-copy.copy.personalNotes", fallback: "desktop.dm.you")
    }

    /// "Chief of Staff" (desktop `boardCopy.chiefOfStaff`). Until the key lands, the platform's
    /// own frozen name from the 1.3 capability, else the export's "Assistant".
    func chiefOfStaff(platformName: String?) -> String {
        // PENDING-COPY:shared.matrix-company-board-copy.copy.chiefOfStaff
        let key = "shared.matrix-company-board-copy.copy.chiefOfStaff"
        if design.copy.contains(key) { return design.text(key) }
        if let platformName, !platformName.isEmpty { return platformName }
        return design.text("shared.matrix-alias-copy.copy.assistant")
    }

    /// The row's state line (desktop `matrixCompanyPrivateCosRowCopy`, `…PrivateCosCopy.paused`).
    func line(_ status: CompanyPrivateCosRowStatus) -> String? {
        switch status {
        case .ready: return nil
        // Same words, same meaning: an assistant row still being set up.
        case .settingUp: return design.text("src.matrix.assistant-card.copy.assistantCardCopies.setupRowWorking")
        case .paused: return design.text("desktop.atum.awareness.states.paused")
        case .notAvailable:
            // PENDING-COPY:shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosRowCopy.notAvailable
            return pending("shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosRowCopy.notAvailable",
                           fallback: "src.matrix.assistant-card.copy.assistantCardCopies.setupRowNotReady")
        }
    }

    var retry: String { design.text("shared.matrix-company-copy.copy.retry") }
    var openFailed: String { ConversationCopy(design: design).openFailed }
}
