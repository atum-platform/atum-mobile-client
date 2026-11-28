import AtumChat
import SwiftUI

/// S9 · The one quiet "Private" row at chat creation (mockup M4 `new`,
/// `new-private`). Off by default. It is not drawn at all until this phone
/// can create a private chat (verified, recovery on, key saved); there is no
/// disabled teaser and no setup prompt here. Turned on, the line under it adds
/// the one-way note. Nothing else changes in the creation sheet.
///
/// The host reads readiness with `.privateChatReadiness(...)` on its Form:
/// a hidden section has no rows, so it cannot run its own lifecycle tasks.
struct PrivateChatOptionSection: View {
    let design: LiveDesign
    let shown: Bool
    @Binding var isOn: Bool
    var disabled = false

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: SecurityCopy { SecurityCopy(design: design) }

    var body: some View {
        if shown {
            Section {
                Toggle(isOn: $isOn) {
                    Text(copy.text(.privateLabel))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                }
                .tint(atum.color(.ink, scheme: scheme))
                .disabled(disabled)
                .accessibilityHint(footnote)
                .accessibilityIdentifier("home.private.toggle")
            } footer: {
                Text(footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("home.private.note")
            }
        }
    }

    private var footnote: String {
        isOn ? copy.text(.privateHelp) + " " + copy.text(.privateOneWay) : copy.text(.privateHelp)
    }
}

extension View {
    /// Readiness can change after setup, restore, verification or a return
    /// to the foreground. Losing it turns Private off and hides the row.
    func privateChatReadiness(_ actions: PrivateChatActions?, shown: Binding<Bool>,
                              isOn: Binding<Bool>) -> some View {
        modifier(PrivateChatReadiness(actions: actions, shown: shown, isOn: isOn))
    }
}

private struct PrivateChatReadiness: ViewModifier {
    let actions: PrivateChatActions?
    @Binding var shown: Bool
    @Binding var isOn: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                guard scenePhase == .active, let actions else {
                    if actions == nil { shown = false; isOn = false }
                    return
                }
                let ready = await actions.readiness()
                guard !Task.isCancelled else { return }
                withMotion(.quick) {
                    shown = PhoneTrustPrivateOption.isShown(canCreatePrivateChat: ready)
                    if !shown { isOn = false }
                }
            }
    }
}

extension PrivateChatCreateResult {
    /// The single line a creation sheet shows for a private refusal.
    @MainActor func notice(_ copy: SecurityCopy) -> String? {
        switch self {
        case .peopleOnly: copy.text(.privatePeopleOnly)
        case .notReady: copy.text(.privateNotReady)
        case .openRoom, .notFound, .rateLimited, .failed: nil
        }
    }
}
