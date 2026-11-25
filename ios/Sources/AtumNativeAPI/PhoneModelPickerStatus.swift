import Foundation

/// The picker's settled read lines (W4-X2), derived only from the read states
/// W4-X1 publishes. Desktop #126 (`a55f1f3f`, `model-picker.tsx`
/// `relayReadReason` and `catalogState`) draws a bounded loading line while a
/// source is in flight and, once a read fails, its note with Try again. A quiet
/// `unavailable` source keeps its existing treatment (a saved row's reason, a
/// Connect entry or nothing) and gets no line of its own.
public struct PhoneModelPickerStatus: Equatable, Sendable, Identifiable {
    public enum Source: String, CaseIterable, Equatable, Sendable {
        /// The assistant's destination readback (1.3 / 1.4 / 1.5).
        case destination
        case chatGPT
        case openCodeGo
        /// The account Connections registry (`atum.account-connections/1`).
        case accountConnections
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case failed
    }

    public let source: Source
    public let phase: Phase
    public var id: Source { source }
    /// Only a failed read offers Try again; a loading one is already bounded.
    public var offersRetry: Bool { phase == .failed }

    public init(source: Source, phase: Phase) {
        self.source = source
        self.phase = phase
    }

    /// The destination's own line. It is drawn apart from the provider lines:
    /// a failed readback leaves every loaded catalog visible and read-only.
    public static func destination(_ state: PhoneModelPickerReadState) -> Self? {
        line(.destination, state)
    }

    /// One line per account source still loading or failed, in the picker's
    /// provider order. No account read at all (nil) draws nothing.
    public static func providers(_ account: PhoneSubscriptionAccount?) -> [Self] {
        guard let account else { return [] }
        return [
            line(.chatGPT, account.chatGPTState),
            line(.openCodeGo, account.openCodeGoState),
            line(.accountConnections, account.accountConnectionsState),
        ].compactMap { $0 }
    }

    /// Whether a listed row already carries this line's words (a saved plan
    /// model whose reason reads loading or failed). Desktop shows that reason
    /// on the row only, so the line then keeps its source and Try again but
    /// drops the repeated words (W4-X2 r2).
    public func isShownOnRow(in rows: [PhoneModelPickerProjection.Row]) -> Bool {
        let plan: ManagedModelDestinationSource
        switch source {
        case .chatGPT: plan = .chatGPTPlan
        case .openCodeGo: plan = .opencodeGo
        case .destination, .accountConnections: return false
        }
        let reason: PhoneModelPickerProjection.Row.Unavailable = phase == .loading ? .loading : .failed
        return rows.contains { $0.isSubscription && $0.source == plan && $0.unavailable == reason }
    }

    private static func line(_ source: Source, _ state: PhoneModelPickerReadState) -> Self? {
        switch state {
        case .loading: Self(source: source, phase: .loading)
        case .failed: Self(source: source, phase: .failed)
        case .ready, .unavailable: nil
        }
    }
}
