import AtumDesign
import SwiftUI

enum FirstRunCopyKey: String, CaseIterable, Sendable {
    case greeting = "shared.matrix-first-run-copy.copies.greeting"
    case greetingWithoutFirstName = "shared.matrix-first-run-copy.copies.greeting.firstName=null"
}

/// The pinned first-run greeting, resolved from the committed `AtumCopy` that
/// `LiveDesign` already loaded. There is no Swift-authored translation source
/// and no missing-key fallback: both keys and arguments come from the desktop
/// export contract in all five supported locales.
@MainActor
struct FirstRunCopy {
    private let resolve: @MainActor (String, [String]) -> String

    init(design: LiveDesign) {
        self.init(design: design, locale: design.locale)
    }

    /// Explicit locale for catalog/contract tests; production uses the app's
    /// selected `LiveDesign.locale`.
    init(design: LiveDesign, locale: String) {
        resolve = { key, arguments in
            do {
                let value = try design.copy.text(
                    key,
                    locale: locale,
                    arguments: arguments.map(AtumCopy.Argument.text)
                )
                guard !value.isEmpty else {
                    preconditionFailure("Empty production first-run copy: \(key)")
                }
                return value
            } catch {
                preconditionFailure("Invalid production first-run copy: \(key)")
            }
        }
    }

    /// Test seam: records the selected key and arguments without parsing the
    /// catalog again.
    init(resolve: @escaping @MainActor (String, [String]) -> String) {
        self.resolve = resolve
    }

    /// Both exported greeting keys require two arguments. When the profile has
    /// no usable first name, select the null branch explicitly; its format
    /// ignores the first argument and inserts the assistant name as `%2$@`.
    func greeting(firstName: String?, assistantName: String) -> String {
        if let firstName {
            return resolve(FirstRunCopyKey.greeting.rawValue, [firstName, assistantName])
        }
        return resolve(FirstRunCopyKey.greetingWithoutFirstName.rawValue, ["", assistantName])
    }
}

enum FirstRunMarkerState: Equatable, Sendable {
    case unseen
    case answered
    case unknown
}

enum FirstRunPresentationPolicy {
    static func shouldOffer(marker: FirstRunMarkerState, persistedAssistantName: String) -> Bool {
        marker == .unseen && !persistedAssistantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A short profile name for the greeting, never an address or a whole biography.
    static func firstName(displayName: String?, userID: String?) -> String? {
        guard let candidate = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty, !candidate.hasPrefix("@"), candidate.count <= 24 else { return nil }
        let local = userID.flatMap { value -> String? in
            guard value.hasPrefix("@"), let separator = value.firstIndex(of: ":") else { return nil }
            return String(value[value.index(after: value.startIndex)..<separator])
        }
        return candidate == local ? nil : candidate
    }
}

enum FirstRunDraftPolicy {
    static func dismissesUnsolicitedPresentation(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The greeting has no draft write action. This helper makes that contract
    /// explicit and testable at the integration boundary.
    static func preserved(_ draft: String) -> String { draft }
}

struct FirstRunContext {
    let accountID: String
    let deviceID: String
    let assistantID: String
    let marker: FirstRunMarkerState
    let personDisplayName: String?
    let persistedAssistantName: String
    let assistantIsDefault: Bool

    var scope: String {
        Self.scope(accountID: accountID, deviceID: deviceID, assistantID: assistantID)
    }

    /// An account, device or assistant change is a hard presentation fence.
    static func scope(accountID: String, deviceID: String, assistantID: String) -> String {
        [accountID, deviceID, assistantID].joined(separator: "\u{0}")
    }
}

/// The first run now starts as a normal greeting in the primary assistant's
/// empty chat. It never renames the assistant, asks for connections, writes an
/// account-data answer, or mutates/sends the person's composer draft.
struct FirstRunGreetingView: View {
    let design: LiveDesign
    let context: FirstRunContext
    @Binding var composerDraft: String

    @State private var dismissed: Bool
    @Environment(\.colorScheme) private var scheme

    private var copy: FirstRunCopy { FirstRunCopy(design: design) }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var eligible: Bool {
        FirstRunPresentationPolicy.shouldOffer(marker: context.marker,
                                               persistedAssistantName: context.persistedAssistantName)
    }

    init(design: LiveDesign, context: FirstRunContext, composerDraft: Binding<String>) {
        self.design = design
        self.context = context
        _composerDraft = composerDraft
        _dismissed = State(initialValue: FirstRunDraftPolicy.dismissesUnsolicitedPresentation(
            composerDraft.wrappedValue
        ))
    }

    var body: some View {
        Group {
            if eligible, !dismissed {
                // FlowPhone2 › First run: the greeting is the assistant's first
                // answer, a Kit answer card (`surface`, `shadow-1`, radius 20,
                // 9/14), with no face in the 1:1 chat.
                HStack(spacing: 0) {
                    Text(copy.greeting(
                        firstName: FirstRunPresentationPolicy.firstName(
                            displayName: context.personDisplayName,
                            userID: context.accountID
                        ),
                        assistantName: context.persistedAssistantName
                    ))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(atum.kitColor(.surface, scheme: scheme),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .atumKitElevation(.one, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Spacer(minLength: 32)
                }
                .frame(maxWidth: 544)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .atumDesign(visual: atum)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("first-run.greeting")
            }
        }
        .onChange(of: composerDraft) { _, value in
            if FirstRunDraftPolicy.dismissesUnsolicitedPresentation(value) { dismissed = true }
        }
        .onChange(of: context.scope) { _, _ in
            dismissed = FirstRunDraftPolicy.dismissesUnsolicitedPresentation(composerDraft)
        }
    }
}
