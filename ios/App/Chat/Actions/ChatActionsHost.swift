import AtumChat
import SwiftUI

/// The open chat's ML6 state: the forward picker request, the link cards of
/// this chat and session, and the room-upgrade band.
@MainActor
@Observable
final class ChatActionsLive {
    var forwardRequest: ForwardPickerRequest?
    private(set) var cards: ChatLinkPreviewCards?
    var upgrade = RoomUpgradeBandState()
    var following = false
    /// A just-joined replacement sync has not published yet: open it on the
    /// next publication if it then confirms (handoff "re-read").
    @ObservationIgnored var pendingReplacementID: String?
    @ObservationIgnored private var cardsKey: CardsKey?

    struct CardsKey: Equatable {
        let session: ObjectIdentifier
        let roomID: String
    }

    func attachCards(_ key: CardsKey?, make: () -> ChatLinkPreviewCards?) {
        guard key != cardsKey else { return }
        cards?.close()
        cards = nil
        cardsKey = key
        if key != nil { cards = make() }
    }

    func close() {
        cards?.close()
        cards = nil
        cardsKey = nil
        forwardRequest = nil
        pendingReplacementID = nil
    }
}

/// Chat parity ML6 on one pushed chat (used by `AppRoot.chatHost`, beside
/// `GroupThreadsHost`): Forward in the long-press menu and its picker (S10),
/// link cards in plain rooms (S11), and the upgrade band with its explicit
/// join and earlier-history link (S15). The room mention row (S14) lives in
/// the composer's `@` list, on the store.
struct ChatActionsHost: ViewModifier {
    let model: LiveAppModel
    let design: LiveDesign
    let roomID: String
    /// The existing access route (`AppRoot.openRoomAndRoute`), including
    /// directory authorization in Team Space.
    let openRoom: @MainActor (String) async -> Bool

    @State private var live = ChatActionsLive()

    private struct SessionKey: Equatable {
        let session: ObjectIdentifier?
        let ready: Bool
        /// A room-list or room-info publication for this chat, or a room
        /// joining or leaving the list.
        let row: LiveMatrixRoomRow?
        let roomCount: Int
    }

    private var sessionKey: SessionKey {
        let session = model.liveMatrix
        return SessionKey(session: session.map { ObjectIdentifier($0) }, ready: session?.isReady == true,
                          row: session?.rooms.first { $0.roomID == roomID },
                          roomCount: session?.rooms.count ?? 0)
    }

    /// Desktop leaves Notes out of the band (`!notesSelfKnownRoom`).
    private var offersUpgradeBand: Bool {
        if case .notesSelf = model.companyWorkspace.roomClassification(roomID) { return false }
        return true
    }

    func body(content: Content) -> some View {
        let forward = model.roomForwardMenuContext(roomID: roomID).map { context in
            ChatForwardMenu(context: context) { [live, design] eventID, row, roomTitle in
                let name = ChatRowText.senderName(row, roomTitle: roomTitle, copy: ChatCopy(design: design))
                live.forwardRequest = ForwardPickerRequest(eventID: eventID, sourceName: name)
            }
        }
        content
            .environment(\.chatForwardMenu, forward)
            .environment(\.chatLinkPreviews, live.cards)
            .safeAreaBar(edge: .top) {
                RoomUpgradeBand(state: live.upgrade, design: design, busy: live.following,
                                follow: { Task { await follow() } },
                                openEarlier: { Task { await openEarlier() } })
            }
            .sheet(item: Binding(get: { live.forwardRequest }, set: { live.forwardRequest = $0 })) { request in
                ForwardPickerSheet(model: pickerModel(request), design: design,
                                   refreshKey: sessionKey.roomCount,
                                   loadThumbnail: { [model] uri, side in
                                       await model.avatarThumbnail(uri: uri, pixelSide: side)
                                   })
                    .atumDesign(design)
            }
            .task(id: sessionKey) { await refresh(sessionKey) }
            .onDisappear { live.close() }
    }

    // MARK: S10

    private func pickerModel(_ request: ForwardPickerRequest) -> ForwardPickerModel {
        let teamName: String? = switch model.companyWorkspace.roomClassification(roomID) {
        case let .company(claim): model.companyWorkspace.companyName(claim.companyID)
        case let .conversation(claim): model.companyWorkspace.companyName(claim.companyID)
        default: nil
        }
        return ForwardPickerModel(sourceName: request.sourceName, teamName: teamName) { [model, live, roomID] in
            // False once the picker or source chat was replaced, dismissed
            // or switched accounts; the sheet's task cancels on dismissal.
            let forwarding = try await model.prepareForward(roomID: roomID, eventID: request.eventID) {
                live.forwardRequest?.id == request.id && model.conversation?.roomID == roomID
            }
            return ForwardPickerSession(preview: forwarding.preview,
                                        targets: { try await forwarding.targets(matching: $0) },
                                        send: { try await forwarding.send(to: $0) })
        }
    }

    // MARK: S11 and S15

    private func refresh(_ key: SessionKey) async {
        guard key.ready, let session = model.liveMatrix else {
            live.attachCards(nil) { nil }
            live.upgrade = RoomUpgradeBandState()
            return
        }
        live.attachCards(.init(session: ObjectIdentifier(session), roomID: roomID)) {
            guard let previews = model.openRoomLinkPreviews(roomID: roomID) else { return nil }
            return ChatLinkPreviewCards(url: { $0.linkPreviewURL }, read: { await previews.card(for: $0) },
                                        onClose: { previews.close() })
        }
        guard offersUpgradeBand else {
            live.upgrade = RoomUpgradeBandState()
            return
        }
        let continuity = await session.roomUpgradeContinuity(roomID: roomID)
        guard !Task.isCancelled, model.liveMatrix === session else { return }
        if live.upgrade.continuity != continuity {
            live.upgrade = RoomUpgradeBandState(continuity: continuity, followFailed: false)
        }
        if let pending = live.pendingReplacementID, continuity.successor == .open(roomID: pending) {
            live.pendingReplacementID = nil
            await open(pending)
        }
    }

    /// Desktop `joinSuccessor`: join on this tap only, confirm the
    /// replacement's create event points back, then open it.
    private func follow() async {
        guard !live.following, let session = model.liveMatrix else { return }
        let replacementID: String
        switch live.upgrade.continuity.successor {
        case let .join(roomID)?, let .open(roomID)?: replacementID = roomID
        default: return
        }
        live.following = true
        defer { live.following = false }
        let result = await session.followRoomUpgrade(roomID: roomID, replacementID: replacementID)
        guard model.liveMatrix === session, model.conversation?.roomID == roomID else { return }
        switch result {
        case .open(let opened) where opened == replacementID:
            await open(opened)
        case .waitingForState:
            live.pendingReplacementID = replacementID
        case .open, .join, .unavailable:
            live.upgrade.followFailed = true
        }
    }

    private func open(_ replacementID: String) async {
        let session = model.liveMatrix
        let opened = await openRoom(replacementID)
        guard opened || model.liveMatrix !== session else {
            live.upgrade.followFailed = true
            return
        }
    }

    /// The earlier room through the same existing navigation, even when the
    /// main roster hides its row.
    private func openEarlier() async {
        guard let earlier = live.upgrade.continuity.earlierRoomID else { return }
        live.following = true
        defer { live.following = false }
        _ = await openRoom(earlier)
    }
}
