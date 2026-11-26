import AtumChat
import AtumDesign
import AtumNativeAPI
import ImageIO
import SwiftUI
import Textual
import UIKit

// The long-press menu (revamp plan B20–B22, §2.7, §3.5), drawn to the Kit's
// FlowPhone3 › Message actions: over a dimmed chat, a glass reaction capsule
// (desktop's set) above the message and a short glass menu under it: "Trả
// lời", "Sao chép", "Chọn văn bản" on answers, "Sửa" on my messages in people
// chats, "Xóa" (danger) on my messages. The system `contextMenu(menuItems:
// preview:)` was weighed first (review A1): its preview is not interactive,
// so it cannot carry the reaction capsule, and it has no reaction accessory
// API. So this stays a custom overlay presented from the long press, laid out
// as the system lifts a preview (see `MessageActionsOverlay`). Which items a
// row offers is `MessageMenuRules` (tested); every action goes through the
// frozen `ChatActions`, which the store enforces again.
//
// The sheets the menu and the failed-send mark open (select text, the delete
// confirmation, "Thử lại" / "Xóa") hang once on the chat screen
// (`messageActionSheets`), driven by one `MessageActionsPresenter`, so a row
// recycled by the lazy stack never owns a presentation.

/// What the menu and the failed-send mark ask the chat screen to present.
/// One per chat screen, handed to rows through the environment
/// (`messageActions`).
@MainActor
@Observable
final class MessageActionsPresenter {
    var selectText: SelectTextRequest?
    var deleteRequest: DeleteRequest?
    var failedSend: FailedSendRequest?
    /// "Báo cáo" on someone else's message: the report sheet (HC-2).
    var reportRequest: ReportMessageRequest?
    /// The message-actions overlay on screen, if any.
    var actionsOverlay: MessageOverlayRequest?
    /// The row whose lifted copy the overlay draws now; that row hides itself
    /// while the copy is up (polish P3), and only then, so it never blinks out
    /// before the cover is on screen.
    var liftedRowID: String?
    /// The overlay part under the finger that opened the menu, while that
    /// finger slides (polish P3: press, slide on to an action, let go).
    var highlighted: MessageMenuTarget?
    /// Where each overlay part sits on screen (global), for the sliding finger.
    @ObservationIgnored var targetFrames: [MessageMenuTarget: CGRect] = [:]
    /// Runs one overlay part, as a tap on it does; the overlay sets it while it shows.
    @ObservationIgnored var commitTarget: ((MessageMenuTarget) -> Void)?
    /// What a menu item still has to do once the cover has gone: a sheet or the
    /// delete alert can only be presented then (`fullScreenCover`'s `onDismiss`).
    @ObservationIgnored var afterOverlay: (() -> Void)?

    /// Where the opening finger was when the menu opened (global).
    @ObservationIgnored private var pressStart: CGPoint?
    /// A finger must travel this far before it selects anything, so a press
    /// released where it began never runs the part that landed under it
    /// (the system's menus behave the same).
    static let slideDistance: CGFloat = 10

    /// The menu opened under a finger that is still down at `location`.
    func pressBegan(at location: CGPoint) {
        pressStart = location
    }

    /// The opening finger moved: highlight the part under it, if any.
    func slide(to location: CGPoint) {
        guard actionsOverlay != nil, let start = pressStart,
              hypot(location.x - start.x, location.y - start.y) >= Self.slideDistance else { return }
        let hit = targetFrames.first { $0.value.contains(location) }?.key
        if hit != highlighted { highlighted = hit }
    }

    /// The opening finger lifted at `location`: on a part, run it (tested
    /// again here, since a quick flick can arrive before the parts are laid
    /// out); anywhere else the menu stays open for a tap, as the system's does.
    func release(at location: CGPoint) {
        slide(to: location)
        #if DEBUG
        // `-AtumUITestProbeDir` only: the lift against the parts' frames, for the P3 captures.
        let frames = targetFrames.map { "\($0.key)=\(Int($0.value.minX)),\(Int($0.value.minY)),"
            + "\(Int($0.value.width))x\(Int($0.value.height))" }.sorted().joined(separator: " ")
        UITestProbe.append("release at=\(Int(location.x)),\(Int(location.y)) start=\(String(describing: pressStart)) "
                           + "hit=\(String(describing: highlighted)) frames=\(frames)", to: "menu-press.txt")
        #endif
        pressStart = nil
        guard let target = highlighted else { return }
        highlighted = nil
        commitTarget?(target)
    }

    /// The opening finger's press was cancelled or failed (the system took
    /// the touch): nothing runs, the menu stays open for a tap, and no part
    /// stays highlighted.
    func pressCancelled() {
        pressStart = nil
        highlighted = nil
    }

    /// The cover has gone: forget the overlay's parts and run what waited for it.
    func overlayDismissed() {
        guard actionsOverlay == nil else { return }
        pressStart = nil
        // The row stayed sunk under its copy until now (`MessageMenuModifier`
        // counts `liftedRowID` as pressed); it springs back here, animated.
        // The cover went in a transaction with animations off, so this one
        // starts fresh and the row's own press animation applies.
        withTransaction(Transaction()) { liftedRowID = nil }
        highlighted = nil
        targetFrames = [:]
        commitTarget = nil
        let after = afterOverlay
        afterOverlay = nil
        #if DEBUG
        UITestProbe.append("overlay dismissed pendingAction=\(after != nil)", to: "menu-press.txt")
        #endif
        after?()
    }
    /// A link tapped in the select-text sheet (B17): the sheet closes first
    /// and the link is routed once it has gone, because the chat screen
    /// presents the in-app page or the held-link line, and SwiftUI presents
    /// nothing from under a presented sheet.
    @ObservationIgnored var linkAfterSelectText: String?
    /// "Reply in thread" (TS-6b): opens the room's thread panel on this root.
    /// Set only in a Team Space channel or conversation; nil offers no item.
    var openThread: ((String) -> Void)?

    /// The select-text sheet's link tap: close the sheet, then route.
    func openLinkFromSelectText(_ url: String) {
        linkAfterSelectText = url
        selectText = nil
    }

    /// A system menu, sheet or delete confirmation covers the chat: its bottom does
    /// not count as visible, so no receipt goes out meanwhile (B13).
    var covers: Bool {
        actionsOverlay != nil || selectText != nil || deleteRequest != nil || failedSend != nil
            || reportRequest != nil
    }

    /// B8: tapping "Chưa gửi được" under a failed bubble (the row view's
    /// mark) offers "Thử lại" and "Xóa".
    func showFailedSend(_ row: ChatRow) {
        failedSend = FailedSendRequest(itemID: row.id, body: row.item.body,
                                       kind: row.item.kind, media: row.item.media)
    }
}

/// "Báo cáo" on one message: the sheet asks for an optional reason first.
struct ReportMessageRequest: Identifiable, Equatable {
    let itemID: String
    var id: String { itemID }
}

/// "Xóa với mọi người?" for one of my messages (B20; desktop asks the same).
struct DeleteRequest: Identifiable, Equatable {
    let itemID: String
    /// My assistant's name in an assistant chat: it may still remember what
    /// it read (desktop's note).
    let assistantName: String?
    var id: String { itemID }
}

extension EnvironmentValues {
    // P4: a key a transcript row reads must also be listed in
    // `TranscriptRowEnvironment.forwarded` (TranscriptView.swift); the hosted
    // cells do not inherit it. tests/test_transcript_row_environment.py checks.
    /// The chat screen's presenter, for row views (the failed-send mark).
    @Entry var messageActions: MessageActionsPresenter?
}

extension View {
    /// B20: the long-press menu for one row. Rows with nothing to act on
    /// (non-actionable notices, placeholders, virtual rows) get no menu. `ownUserID` marks
    /// the reactions I already gave (nil: none marked); `parsedBody` is the
    /// store's parse of an answer (`ConversationStore.parsedBody(for:)`), so
    /// the preview and the select-text sheet never parse again.
    func messageMenu(row: ChatRow, kind: RoomKind, roomTitle: String, ownUserID: String?,
                     parsedBody: AttributedString?, design: LiveDesign, actions: ChatActions,
                     presenter: MessageActionsPresenter) -> some View {
        modifier(MessageMenuModifier(row: row, kind: kind, roomTitle: roomTitle, ownUserID: ownUserID,
                                     parsedBody: parsedBody, design: design, actions: actions, presenter: presenter))
    }

    /// The menu's and the failed-send mark's presentations, once per chat
    /// screen: the select-text sheet, the delete confirmation and the
    /// failed-send sheet.
    func messageActionSheets(_ presenter: MessageActionsPresenter, design: LiveDesign,
                             actions: ChatActions) -> some View {
        modifier(MessageActionSheets(presenter: presenter, design: design, actions: actions))
    }
}

/// One part of the overlay a finger can slide on to: a menu row or a reaction.
enum MessageMenuTarget: Hashable {
    case item(MessageMenuItem)
    case reaction(String)
}

/// One long press on an event row opens the actions overlay for it.
struct MessageOverlayRequest: Identifiable {
    let row: ChatRow
    let kind: RoomKind
    let roomTitle: String
    let ownUserID: String?
    let parsedBody: AttributedString?
    let items: [MessageMenuItem]
    /// The row's frame on screen when it was pressed.
    let sourceFrame: CGRect
    var id: String { row.id }
}

private struct MessageMenuModifier: ViewModifier {
    let row: ChatRow
    let kind: RoomKind
    let roomTitle: String
    let ownUserID: String?
    let parsedBody: AttributedString?
    let design: LiveDesign
    let actions: ChatActions
    let presenter: MessageActionsPresenter

    @State private var frame: CGRect = .zero
    /// The finger is down on the row and the press has not reached the menu yet.
    /// Set by `MenuPressSink` (UIKit), not a SwiftUI `@GestureState`: a long
    /// press with `.updating` on every row left the transcript unable to
    /// scroll after the keyboard went (PR #109's hosted shard 2,
    /// `testQuotesInBothBubblesMeetContrast`).
    @State private var pressing = false
    @Environment(\.chatReducesMotion) private var reduceMotion
    /// P4: the transcript's pan. A press that the list has started to
    /// scroll never opens the menu (`ChatRowInteractions.scroll`).
    @Environment(\.chatRowInteractions) private var interactions

    /// How long a press takes to open the menu.
    static let pressDuration: Double = 0.35
    /// The row shrinks to this while pressed, as the system's previews and
    /// Telegram's bubbles do; the overlay's copy lifts from it.
    static let pressedScale: CGFloat = 0.96
    /// A touch that is only passing (a scroll, a tap) shows no shrink.
    static let pressDelay: Double = 0.08
    /// The lifted row: invisible, but still hit-testable.
    static let liftedOpacity: Double = 0.001

    func body(content: Content) -> some View {
        let items = MessageMenuRules.items(for: row.item, in: kind, threads: presenter.openThread != nil)
        if items.isEmpty {
            content
        } else {
            // Review A1: while its menu is open the row is lifted, so the
            // original is hidden and only the overlay's copy shows (the
            // system context menu does the same). The overlay is modal, so
            // VoiceOver never reaches the hidden row either.
            let source = presenter.actionsOverlay?.id == row.id
            let lifted = source && presenter.liftedRowID == row.id
            // Polish P3 (audit issue 5): press anticipation. The row sinks
            // while the finger is down and stays sunk under its lifted copy,
            // so the copy rises from it and lands back on it. It stays sunk
            // until the cover has gone (`liftedRowID` is cleared in
            // `overlayDismissed`, animated), so it springs back from 0.96
            // instead of snapping to full size with the cover's last frame
            // (fix round 2). Under Reduce Motion it never sinks.
            let pressed = (pressing || source || presenter.liftedRowID == row.id) && !reduceMotion
            content
                .scaleEffect(pressed ? Self.pressedScale : 1)
                .animation(pressAnimation(down: pressed), value: pressed)
                // Measured outside the shrink: the overlay places the copy at
                // the row's own size.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                // Not 0: SwiftUI stops hit-testing a fully transparent view,
                // and the finger that opened the menu is still on this row
                // (`MenuPressFollower`). The overlay's opaque copy and its
                // blur cover what is left.
                .opacity(lifted ? Self.liftedOpacity : 1)
                .accessibilityHidden(lifted)
                // Simultaneous, so the answer's own text views (links, the
                // markdown renderer) never swallow the press.
                .simultaneousGesture(pressGesture(items))
                .gesture(MenuPressSink(delay: Self.pressDelay, scroll: interactions.scroll) { pressing = $0 })
                .gesture(followRecognizer(items))
                // One medium tick when the menu opens, never when it closes.
                .sensoryFeedback(.impact(weight: .medium), trigger: source) { _, opened in opened }
                // VoiceOver: every item is an action on the message itself.
                .accessibilityActions {
                    ForEach(items.filter { $0 != .react }, id: \.self) { item in
                        Button(MessageMenuActions.title(item, design: design)) {
                            MessageMenuActions.perform(item, row: row, kind: kind, roomTitle: roomTitle,
                                                       parsedBody: parsedBody, actions: actions,
                                                       presenter: presenter)
                        }
                    }
                    if items.contains(.react) {
                        Button(ChatCopy.text(design, ChatCopy.Key.react)) { open(items) }
                    }
                }
        }
    }

    /// Down: a gentle sink (the touch has already stayed `pressDelay`, see
    /// `MenuPressSink`). Up: a quick return.
    private func pressAnimation(down: Bool) -> Animation? {
        down ? ChatMotion.animation(.standard, reduceMotion: reduceMotion)
             : ChatMotion.animation(.quick, reduceMotion: reduceMotion)
    }

    /// Hold to open: the menu opens at the threshold. A touch that moves
    /// first is a scroll and fails the press. The sink while the finger is
    /// down comes from `MenuPressSink`.
    private func pressGesture(_ items: [MessageMenuItem]) -> some Gesture {
        LongPressGesture(minimumDuration: Self.pressDuration)
            .onEnded { _ in open(items) }
    }

    /// The same press, followed after the threshold, as the system's context
    /// menus behave: keep the finger down, slide on to an action or a
    /// reaction and let go to run it; letting go anywhere else leaves the
    /// menu open for a tap. The transcript stops scrolling while the menu is
    /// up. UIKit's long press, because it is continuous (began at the
    /// threshold, changed while the finger moves, ended on lift). The lift is
    /// hit-tested again where it happens: a finger that reached its target
    /// before the menu had laid its parts out still runs it (P3 run 5's
    /// probe: a quick flick arrives before the targets exist).
    private func followRecognizer(_ items: [MessageMenuItem]) -> MenuPressFollower {
        MenuPressFollower(duration: Self.pressDuration, scroll: interactions.scroll,
                          began: { location in
                              open(items)
                              guard presenter.actionsOverlay?.id == row.id else { return }
                              presenter.pressBegan(at: location)
                          },
                          moved: { location in
                              guard presenter.actionsOverlay?.id == row.id else { return }
                              presenter.slide(to: location)
                          },
                          ended: { location in
                              guard presenter.actionsOverlay?.id == row.id else { return }
                              presenter.release(at: location)
                          },
                          cancelled: {
                              guard presenter.actionsOverlay?.id == row.id else { return }
                              presenter.pressCancelled()
                          })
    }

    private func open(_ items: [MessageMenuItem]) {
        guard presenter.actionsOverlay == nil, !interactions.scroll.isScrolling() else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presenter.actionsOverlay = MessageOverlayRequest(row: row, kind: kind, roomTitle: roomTitle,
                                                             ownUserID: ownUserID, parsedBody: parsedBody,
                                                             items: items, sourceFrame: frame)
        }
    }
}

/// Whether a finger is resting on a row (polish P3's press anticipation):
/// `true` once a touch has stayed `delay` without moving, `false` when it
/// lifts, is cancelled (the transcript's pan took it) or drifts past UIKit's
/// allowable movement. UIKit, beside every other touch and never delaying or
/// cancelling one, like `MenuPressFollower`: it only observes.
private struct MenuPressSink: UIGestureRecognizerRepresentable {
    let delay: Double
    let scroll: ChatScrollSignal
    let changed: @MainActor (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = delay
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        scroll.track(recognizer, onlyWaiting: false)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.minimumPressDuration = delay
        scroll.track(recognizer, onlyWaiting: false)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch recognizer.state {
        case .began:
            // A finger resting on a row the list is already scrolling (a
            // slow drag) is not a press.
            guard !scroll.isScrolling() else { return }
            coordinator.start = recognizer.location(in: nil)
            coordinator.down = true
            changed(true)
        case .changed:
            // Resting first and then dragging is a scroll: the row comes back up.
            guard coordinator.down, let start = coordinator.start else { return }
            let point = recognizer.location(in: nil)
            if hypot(point.x - start.x, point.y - start.y) > recognizer.allowableMovement || scroll.isScrolling() {
                coordinator.down = false
                changed(false)
            }
        case .ended, .cancelled, .failed:
            coordinator.start = nil
            if coordinator.down {
                coordinator.down = false
                changed(false)
            }
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint?
        var down = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// UIKit's continuous long press on a row, beside every other touch (links,
/// the markdown renderer, the transcript's own recognizers): it never delays
/// or cancels a touch. `began` at the threshold, `moved` with the finger's
/// place on screen (global), `ended` when it lifts. A cancelled or failed
/// press only reports `cancelled` (the highlight goes); the menu stays open.
private struct MenuPressFollower: UIGestureRecognizerRepresentable {
    let duration: Double
    let scroll: ChatScrollSignal
    let began: @MainActor (CGPoint) -> Void
    let moved: @MainActor (CGPoint) -> Void
    let ended: @MainActor (CGPoint) -> Void
    let cancelled: @MainActor () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = duration
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        // A press the pan takes before the threshold never opens the menu;
        // one that already opened it keeps following the finger.
        scroll.track(recognizer, onlyWaiting: true)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.minimumPressDuration = duration
        scroll.track(recognizer, onlyWaiting: true)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        #if DEBUG
        // `-AtumUITestProbeDir` only: what the follower saw, for the P3 captures.
        let point = context.converter.location(in: .global)
        UITestProbe.append(String(format: "follower state=%d x=%.0f y=%.0f", recognizer.state.rawValue,
                                  point.x, point.y), to: "menu-press.txt")
        #endif
        switch recognizer.state {
        case .began: began(context.converter.location(in: .global))
        case .changed: moved(context.converter.location(in: .global))
        case .ended: ended(context.converter.location(in: .global))
        case .cancelled, .failed: cancelled()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// What each menu item says, shows and does; shared by the overlay and the
/// VoiceOver actions.
@MainActor
enum MessageMenuActions {
    static func title(_ item: MessageMenuItem, design: LiveDesign) -> String {
        switch item {
        case .react: ChatCopy.text(design, ChatCopy.Key.react)
        case .reply: ChatCopy.text(design, ChatCopy.Key.reply)
        case .replyInThread: design.text("src.matrix.thread-copy.copy.replyInThread")
        case .copy: ChatCopy.text(design, ChatCopy.Key.copy)
        case .selectText: ChatCopy.text(design, ChatCopy.Key.selectText)
        case .edit: ChatCopy.text(design, ChatCopy.Key.edit)
        case .report: ChatCopy.text(design, ChatCopy.Key.report)
        case .delete: ChatCopy.text(design, ChatCopy.Key.delete)
        }
    }

    static func glyph(_ item: MessageMenuItem) -> AtumGlyph {
        switch item {
        case .react: .smiley
        case .reply: .arrowBackUp
        // The vendored Phosphor subset has no Messages glyph (desktop's thread mark).
        case .replyInThread: .messageCircle
        case .copy: .copy
        case .selectText: .fileText
        case .edit: .pencil
        // The vendored Phosphor subset has no flag (desktop's Flag); the
        // warning circle is the Kit's nearest mark.
        case .report: .alertCircle
        case .delete: .trash
        }
    }

    /// Whether an item runs only once the menu's cover has gone: everything
    /// that presents (a sheet, the delete alert, the thread panel) or moves the
    /// keyboard on to the composer (Reply, Edit). Copy runs at once.
    static func waitsForCover(_ item: MessageMenuItem) -> Bool {
        switch item {
        case .copy, .react: false
        case .reply, .replyInThread, .selectText, .edit, .report, .delete: true
        }
    }

    static func perform(_ item: MessageMenuItem, row: ChatRow, kind: RoomKind, roomTitle: String,
                        parsedBody: AttributedString?, actions: ChatActions,
                        presenter: MessageActionsPresenter) {
        switch item {
        case .react: break
        case .reply: actions.reply(row.id)
        case .replyInThread:
            if let rootID = MessageMenuRules.threadRootID(for: row.item) { presenter.openThread?(rootID) }
        case .copy: actions.copy(row.id)
        case .selectText:
            presenter.selectText = SelectTextRequest(itemID: row.id, body: row.item.markdownBody,
                                                     parsed: parsedBody)
            #if DEBUG
            UITestProbe.append("select text requested row=\(row.id)", to: "menu-press.txt")
            #endif
        case .edit: actions.edit(row.id)
        case .report: presenter.reportRequest = ReportMessageRequest(itemID: row.id)
        case .delete:
            if MessageMenuRules.deleteNeedsConfirmation(row.item) {
                presenter.deleteRequest = DeleteRequest(itemID: row.id,
                                                        assistantName: kind == .assistant ? roomTitle : nil)
            } else {
                actions.delete(row.id)
            }
        }
    }
}

/// FlowPhone3 › Message actions, laid out the way the system lifts a context
/// menu (review A1): the pressed row is hidden (`MessageMenuModifier`), so only
/// its lifted copy shows; the chat behind sits under a material blur plus the
/// Kit scrim, which separates the layers in light and dark (and turns opaque
/// under Reduce Transparency); and `MessageMenuLayout` keeps the copy where it
/// was pressed with the glass reaction capsule and the glass menu on opposite
/// sides of it, flipping them for a message low on the screen, so neither
/// ever covers the copy, the other, or the bars. A tap outside closes it.
struct MessageActionsOverlay: View {
    let request: MessageOverlayRequest
    let design: LiveDesign
    let actions: ChatActions
    let presenter: MessageActionsPresenter

    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatReducesMotion) private var reduceMotion
    @State private var shown = false
    @State private var closing = false
    @State private var reactionsHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
    @State private var menuHeight: CGFloat = 0
    /// The band's height when the menu opened. A slide towards older messages
    /// may put the keyboard away under the cover; the parts stay where the
    /// finger expects them.
    @State private var frozenHeight: CGFloat?
    /// Review A2: the palette and the menu follow Dynamic Type, within limits
    /// that keep six reactions on one line of a phone.
    @ScaledMetric(relativeTo: .title2) private var emojiSize: CGFloat = 26
    @ScaledMetric(relativeTo: .title2) private var reactionTarget: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var menuWidth: CGFloat = 250

    private var kit: AtumKit { design.kit }
    private var own: Bool { request.row.item.isOwn }
    private var hasReactions: Bool { request.items.contains(.react) }
    private var menuRows: [MessageMenuItem] { request.items.filter { $0 != .react } }

    /// Space kept from the safe area's edges, and between the parts.
    private var margin: CGFloat { kit.space(.s2) }
    private var gap: CGFloat { kit.space(.s2) }
    /// The capsule and the menu grow out of the copy from this scale.
    private static let partScale: CGFloat = 0.6

    // Polish P3 (audit issue 5): the copy is drawn where the row was from the
    // first frame, at the row's pressed size, and springs (`Motion.send`) to
    // its full size and its laid-out place while the capsule and the menu grow
    // out of it; closing runs the same motion back (`Motion.quick`), and the
    // row takes over in the same place. Under Reduce Motion nothing moves or
    // scales: the copy sits at its place and the rest fades.
    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .global)
            let height = frozenHeight ?? proxy.size.height
            let top = Double(margin)
            let bottom = Double(max(margin, height - margin))
            let sourceTop = Double(request.sourceFrame.minY - bounds.minY)
            let layout = MessageMenuLayout.place(
                sourceTop: sourceTop, bounds: top...bottom,
                reactions: hasReactions ? Double(reactionsHeight) : nil,
                preview: Double(previewHeight), menu: Double(menuHeight), gap: Double(gap))
            // The most the copy may take, whatever its own height.
            let room = bottom - top - (hasReactions ? Double(reactionsHeight + gap) : 0)
                - (menuRows.isEmpty ? 0 : Double(menuHeight + gap))
            let measured = previewHeight > 0 && (menuRows.isEmpty || menuHeight > 0)
                && (!hasReactions || reactionsHeight > 0)
            let settled = shown || reduceMotion
            let menuAbove = layout.arrangement == .menuAbove
            // How far the row's own edge sits from the copy's laid-out edge.
            let sourceShift = own
                ? request.sourceFrame.maxX - (bounds.maxX - ChatLayout.sideMargin)
                : request.sourceFrame.minX - (bounds.minX + ChatLayout.sideMargin)
            ZStack(alignment: .topLeading) {
                backdrop
                ZStack(alignment: .topLeading) {
                    if hasReactions {
                        reactions
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reactionsHeight = $0 }
                            .scaleEffect(settled ? 1 : Self.partScale, anchor: partAnchor(below: menuAbove))
                            .opacity(shown && measured ? 1 : 0)
                            .modifier(Placed(top: layout.reactionsTop ?? 0, own: own))
                    }
                    MessageMenuPreview(row: request.row, kind: request.kind, parsedBody: request.parsedBody,
                                       design: design, maxHeight: CGFloat(max(0, room)))
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                        .scaleEffect(settled ? 1 : MessageMenuModifier.pressedScale)
                        .offset(x: settled ? 0 : sourceShift)
                        .opacity(reduceMotion && !shown ? 0 : 1)
                        .modifier(Placed(top: settled && measured ? layout.previewTop : sourceTop, own: own))
                    if !menuRows.isEmpty {
                        menu(width: min(menuWidth, proxy.size.width - 2 * ChatLayout.sideMargin))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                            .scaleEffect(settled ? 1 : Self.partScale, anchor: partAnchor(below: !menuAbove))
                            .opacity(shown && measured ? 1 : 0)
                            .modifier(Placed(top: layout.menuTop, own: own))
                    }
                }
            }
            .onChange(of: measured, initial: true) { _, ready in
                guard ready, !shown, !closing else { return }
                frozenHeight = proxy.size.height
                withAnimation(ChatMotion.animation(.send, reduceMotion: reduceMotion)) { shown = true }
            }
        }
        .onAppear {
            // The copy is on screen from this frame: the row may hide now.
            presenter.liftedRowID = request.id
            presenter.commitTarget = { perform($0) }
        }
        .sensoryFeedback(.selection, trigger: presenter.highlighted) { _, new in new != nil }
        .accessibilityAction(.escape) { close() }
        .atumDesign(design)
    }

    /// A part grows from its edge nearest the copy, on the message's side.
    private func partAnchor(below: Bool) -> UnitPoint {
        switch (below, own) {
        case (true, true): .topTrailing
        case (true, false): .topLeading
        case (false, true): .bottomTrailing
        case (false, false): .bottomLeading
        }
    }

    /// One part, tapped or slid on to and released.
    private func perform(_ target: MessageMenuTarget) {
        switch target {
        case let .reaction(key):
            actions.toggleReaction(request.row.id, key)
            close()
        case let .item(item):
            let request = request
            let actions = actions
            let presenter = presenter
            let run = {
                MessageMenuActions.perform(item, row: request.row, kind: request.kind,
                                           roomTitle: request.roomTitle, parsedBody: request.parsedBody,
                                           actions: actions, presenter: presenter)
            }
            if MessageMenuActions.waitsForCover(item) {
                close(then: run)
            } else {
                run()
                close()
            }
        }
    }

    /// The material dim: blur, then the Kit scrim over it.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            kit.color(.scrim, scheme: scheme)
        }
        .opacity(shown ? 1 : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .accessibilityHidden(true)
        .accessibilityIdentifier(Self.backdropID)
    }

    private var reactions: some View {
        let choices = MessageMenuRules.reactionChoices(for: request.row.item, ownUserID: request.ownUserID)
        let target = min(reactionTarget, 52)
        return HStack(spacing: 2) {
            ForEach(choices, id: \.key) { choice in
                let highlighted = presenter.highlighted == .reaction(choice.key)
                Button {
                    perform(.reaction(choice.key))
                } label: {
                    Text(verbatim: choice.key)
                        .font(.system(size: min(emojiSize, 34)))
                        // The emoji under a sliding finger grows, as the
                        // system's and Telegram's reaction bars do.
                        .scaleEffect(highlighted && !reduceMotion ? Self.highlightedEmojiScale : 1)
                        // At least 44 pt to tap (the Kit's phone control height).
                        .frame(width: target, height: target)
                        .background {
                            if choice.isSelected || highlighted {
                                Circle().fill(kit.color(.fillSelected, scheme: scheme)).padding(kit.space(.s1))
                            }
                        }
                        .contentShape(Circle())
                        .chatMotion(.quick, value: highlighted)
                }
                .buttonStyle(.plain)
                .modifier(TargetFrame(target: .reaction(choice.key), presenter: presenter))
                .accessibilityLabel(ChatCopy.text(design, ChatCopy.Key.reactWith, [.text(choice.key)]))
                .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, kit.space(.s1))
        .padding(.horizontal, kit.space(.s2))
        .modifier(LiveGlass(design: design, radius: Double(kit.phoneRadius(.full))))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.reactionsID)
    }

    private func menu(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(menuRows.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(kit.color(.line, scheme: scheme))
                        .frame(height: 0.5)
                        .padding(.leading, kit.space(.s4))
                }
                Button {
                    perform(.item(item))
                } label: {
                    HStack(spacing: kit.space(.s3)) {
                        Text(MessageMenuActions.title(item, design: design))
                            .font(.body)
                        Spacer(minLength: kit.space(.s2))
                        Image(design.symbol(MessageMenuActions.glyph(item).rawValue))
                            .font(.body)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(kit.color(item == .delete ? .danger : .ink, scheme: scheme))
                    .padding(.horizontal, kit.space(.s4))
                    .frame(minHeight: 46)
                    // The row under a sliding finger shows the system's
                    // pressed fill.
                    .background(presenter.highlighted == .item(item)
                                ? kit.color(.fillSelected, scheme: scheme) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(TargetFrame(target: .item(item), presenter: presenter))
                .accessibilityLabel(MessageMenuActions.title(item, design: design))
            }
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous))
        .modifier(LiveGlass(design: design, radius: Double(kit.phoneRadius(.lg))))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.menuID)
    }

    /// Closes the menu: the parts shrink back into the copy and the copy
    /// returns to the row (`Motion.quick`), then the cover goes and the row
    /// shows again in the same place. `then` runs once the cover has gone
    /// (a sheet or the delete alert needs that), with no timed wait.
    private func close(then after: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        presenter.highlighted = nil
        presenter.commitTarget = nil
        if let after { presenter.afterOverlay = after }
        #if DEBUG
        UITestProbe.append("overlay closing pendingAction=\(after != nil)", to: "menu-press.txt")
        #endif
        let presenter = presenter
        let finish = {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presenter.actionsOverlay = nil }
        }
        guard shown, let animation = ChatMotion.animation(.quick, reduceMotion: reduceMotion) else {
            finish()
            return
        }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            shown = false
        } completion: {
            finish()
        }
    }

    /// The emoji under a sliding finger.
    private static let highlightedEmojiScale: CGFloat = 1.25

    /// The overlay's parts, for UI tests (beside the frozen row IDs).
    static let reactionsID = "menu.reactions"
    static let previewID = "menu.preview"
    static let menuID = "menu.items"
    static let backdropID = "menu.backdrop"

    /// Hands one part's frame on screen to the presenter, for the sliding finger.
    private struct TargetFrame: ViewModifier {
        let target: MessageMenuTarget
        let presenter: MessageActionsPresenter

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                presenter.targetFrames[target] = frame
            }
        }
    }

    /// One part at its layout top, on the message's side of the screen.
    private struct Placed: ViewModifier {
        let top: Double
        let own: Bool

        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
                .padding(.horizontal, ChatLayout.sideMargin)
                .offset(y: CGFloat(top))
        }
    }
}

/// Offers its child at most `maxWidth` and takes the child's own size, so a
/// short message keeps a short bubble and a long one wraps. `maxHeight`
/// caps the height without ever growing a short message to it (a flexible
/// `.frame(maxHeight:)` takes the whole cap when offered more).
private struct HugWidth: Layout {
    let maxWidth: CGFloat
    var maxHeight: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: nil))
        return CGSize(width: size.width, height: min(size.height, maxHeight ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The child keeps its own height; a cut one runs past the bottom and
        // is clipped by the caller.
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The pressed message, lifted above the dimmed chat as a Kit bubble: yours
/// on `bubble-own`, everyone else's on `surface` (FlowPhone3).
private struct MessageMenuPreview: View {
    let row: ChatRow
    let kind: RoomKind
    let parsedBody: AttributedString?
    let design: LiveDesign
    /// The most the bubble may take (`MessageMenuLayout`'s room); a longer
    /// message is cut at the bottom inside its bubble.
    var maxHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let own = row.item.isOwn
        let shape = RoundedRectangle(cornerRadius: ChatLayout.bubbleRadius, style: .continuous)
        HugWidth(maxWidth: 292, maxHeight: maxHeight.map { max(0, $0 - 18) }) { content }
            .clipped()
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .foregroundStyle(design.kit.color(own ? .onBubbleOwn : .ink, scheme: scheme))
            .background(design.kit.color(own ? .bubbleOwn : .surface, scheme: scheme), in: shape)
            .atumKitElevation(.one, in: shape)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(MessageActionsOverlay.previewID)
    }

    @ViewBuilder private var content: some View {
        switch row.item.kind {
        case .image where row.item.media != nil:
            MessageMenuImagePreview(row: row, design: design)
        case .image:
            Label(ChatCopy.text(design, ChatCopy.Key.photo), image: design.symbol("Photo"))
        case let .file(name):
            if let media = row.item.media {
                let kind = media.presentationKind(fallbackFilename: name)
                HStack(spacing: 12) {
                    Image(design.symbol(kind.glyphAlias)).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: media.filename ?? name).lineLimit(2).truncationMode(.middle)
                        Text(ChatCopy.text(design, kind.copyKey)).font(.footnote)
                            .foregroundStyle(design.color("soft", scheme: scheme))
                    }
                }
                .padding(12)
                .background(design.color("cell", scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Label(name, image: design.symbol("File"))
            }
        default:
            if MessageMenuRules.isAnswer(row.item, in: kind) || row.item.privateCosGreeting != nil {
                // Answers render as markdown, from the store's parse; so does the Chief of
                // Staff greeting, whose board URL is never shown raw.
                // Textual turns line limits off inside, so a long answer is
                // cut by height: the preview stays a preview.
                StructuredText(row.item.markdownBody, parser: ParsedOrFreshMarkdown(parsed: parsedBody))
                    .font(.body)
                    .textual.inlineStyle(design.chatInlineStyle(scheme))
                    .frame(maxHeight: Self.maximumContentHeight, alignment: .top)
                    .clipped()
            } else {
                // People's and my own messages show literally (B6).
                Text(verbatim: row.item.body)
                    .font(.body)
                    .lineLimit(14)
            }
        }
    }

    /// About 14 lines of body text.
    private static let maximumContentHeight: CGFloat = 330
}

private struct MessageMenuImagePreview: View {
    let row: ChatRow
    let design: LiveDesign
    @Environment(\.chatMediaAccess) private var access
    @Environment(\.chatLocalMediaFiles) private var localFiles
    @Environment(\.colorScheme) private var scheme
    @State private var image: Image?

    private var size: CGSize {
        guard case let .image(width, height) = row.item.kind,
              let width, let height, width > 0, height > 0 else {
            return CGSize(width: 288, height: 216)
        }
        let previewHeight = 288 * CGFloat(height) / CGFloat(width)
        return CGSize(width: 288, height: min(360, max(120, previewHeight)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                design.color("bubble", scheme: scheme)
                if let image { image.resizable().scaledToFill() }
                else { Image(design.symbol("Photo")).font(.title2) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !row.item.body.isEmpty {
                Text(verbatim: row.item.body).font(.body).lineLimit(6)
            }
        }
        .task(id: row.item.media) {
            let data: Data?
            if let local = localFiles[row.id] {
                data = try? Data(contentsOf: local, options: [.mappedIfSafe])
            } else if let media = row.item.media {
                data = await access.thumbnail(media, Int(size.width * 3), Int(size.height * 3))
            } else {
                data = nil
            }
            guard let data,
                  !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let value = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 3),
                  ] as CFDictionary), !Task.isCancelled else { return }
            image = Image(uiImage: UIImage(cgImage: value))
        }
    }
}

extension LiveDesign {
    /// Textual's inline style for the chat's markdown outside the transcript
    /// (the menu preview, the select-text sheet): links ink and underlined,
    /// as `NativeRichText` draws them. Textual's default link colour is its
    /// own blue and ignores `.tint` (§0.2: monochrome ink accent, never iOS
    /// blue; seen in the S1 review's screenshots).
    func chatInlineStyle(_ scheme: ColorScheme) -> InlineStyle {
        InlineStyle.default.link(.foregroundColor(color("ink", scheme: scheme)), .underlineStyle(.single))
    }
}

/// Hands Textual the store's parse when it is current, so the preview and
/// the select-text sheet never parse on the main actor; parses only when the
/// store has none yet (an answer opened before its parse landed).
struct ParsedOrFreshMarkdown: MarkupParser {
    let parsed: AttributedString?

    func attributedString(for input: String) throws -> AttributedString {
        parsed ?? MessageMarkup.parse(input)
    }
}

/// The presentations, once per chat screen.
private struct MessageActionSheets: ViewModifier {
    @Bindable var presenter: MessageActionsPresenter
    let design: LiveDesign
    let actions: ChatActions

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $presenter.actionsOverlay, onDismiss: { presenter.overlayDismissed() }) { request in
                MessageActionsOverlay(request: request, design: design, actions: actions, presenter: presenter)
                    .presentationBackground(.clear)
                    .onDisappear {
                        // Some cover dismissals remove the content without
                        // running onDismiss. Let that removal finish before
                        // asking the presenter to open a sheet or dialog.
                        Task { @MainActor in presenter.overlayDismissed() }
                    }
            }
            .sheet(item: $presenter.selectText, onDismiss: {
                guard let link = presenter.linkAfterSelectText else { return }
                presenter.linkAfterSelectText = nil
                actions.openLink(link)
            }) { request in
                SelectTextSheet(request: request, design: design) { url in
                    presenter.openLinkFromSelectText(url)
                }
            }
            .sheet(item: $presenter.failedSend) { request in
                FailedSendSheet(request: request, design: design, actions: actions)
            }
            .sheet(item: $presenter.reportRequest) { request in
                ReportSheet(design: design, subject: .message) { reason in
                    await actions.report(request.itemID, reason)
                }
            }
            .alert(ChatCopy.text(design, ChatCopy.Key.deleteMessageTitle),
                   isPresented: Binding(get: { presenter.deleteRequest != nil },
                                        set: { if !$0 { presenter.deleteRequest = nil } }),
                   presenting: presenter.deleteRequest) { request in
                Button(ChatCopy.text(design, ChatCopy.Key.delete), role: .destructive) {
                    actions.delete(request.itemID)
                }
                Button(ChatCopy.text(design, ChatCopy.Key.cancel), role: .cancel) {}
            } message: { request in
                Text(message(request))
            }
    }

    private func message(_ request: DeleteRequest) -> String {
        let body = ChatCopy.text(design, ChatCopy.Key.deleteMessageBody)
        guard let name = request.assistantName, !name.isEmpty else { return body }
        // Two exported sentences, one per line: no separator is written here.
        return body + "\n" + ChatCopy.text(design, ChatCopy.Key.deleteMessageAssistantNote, [.text(name)])
    }
}

/// Report words the export does not carry yet (`ReportPendingCopy`): the key
/// once the pin has it, else its closest exported stand-in.
@MainActor
enum ReportCopy {
    static func text(_ design: LiveDesign, _ key: ReportPendingCopy) -> String {
        if let text = try? design.copy.text(key.rawValue, locale: design.locale) { return text }
        return ChatCopy.text(design, key.fallback)
    }
}

/// The report sheet (desktop `MatrixReportDialog`), for a message or a
/// person: its title, one line, an optional one-line reason and Report.
/// Nothing else is asked; the reason is the person's own words, sent with the
/// Matrix report and never with message content. A failure says so and the
/// sheet stays open; a sent report says "Report sent." for a beat, then the
/// sheet closes.
struct ReportSheet: View {
    enum Subject: Equatable {
        case message
        case person
    }

    let design: LiveDesign
    let subject: Subject
    /// Sends the report with the reason as typed (`ReportPolicy.reason`
    /// trims it); true once the homeserver took it.
    let send: @MainActor (String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var reason = ""
    @State private var status = Status.idle
    @State private var failed = false
    @FocusState private var reasonFocused: Bool

    private enum Status { case idle, sending, sent }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    private var title: String {
        switch subject {
        case .message: ChatCopy.text(design, .reportTitle)
        // PENDING-COPY:src.matrix.chat-copy.copies.reportPersonTitle
        case .person: ReportCopy.text(design, .reportPersonTitle)
        }
    }

    private var line: String {
        switch subject {
        case .message: ChatCopy.text(design, .reportBody)
        // PENDING-COPY:src.matrix.chat-copy.copies.reportPersonBody
        case .person: ReportCopy.text(design, .reportPersonBody)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: line)
                        .font(.subheadline)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    // PENDING-COPY:src.matrix.chat-copy.copies.reportReason
                    TextField(ReportCopy.text(design, .reportReason), text: $reason)
                        .focused($reasonFocused)
                        .submitLabel(.send)
                        .onSubmit(submit)
                        .disabled(status != .idle)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .background(atum.color(.cell, scheme: scheme),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChange(of: reason) { _, new in
                            if new.count > ReportPolicy.reasonLimit {
                                reason = String(new.prefix(ReportPolicy.reasonLimit))
                            }
                        }
                        .accessibilityIdentifier("report.reason")
                    if failed {
                        Label { Text(ChatCopy.text(design, .errorGeneric)) } icon: {
                            Image(atum.symbol(.alertCircle))
                        }
                        .font(.footnote)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .accessibilityIdentifier("report.failed")
                    }
                    if status == .sent {
                        Label { Text(ChatCopy.text(design, .reportSent)) } icon: {
                            Image(atum.symbol(.checkCircle))
                        }
                        .font(.footnote)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .accessibilityIdentifier("report.sent")
                    }
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChatCopy.text(design, .cancel)) { dismiss() }
                        .disabled(status == .sending)
                        .accessibilityIdentifier("report.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        if status == .sending {
                            ProgressView()
                        } else {
                            Text(ChatCopy.text(design, .report))
                        }
                    }
                    .disabled(status != .idle)
                    .accessibilityIdentifier("report.send")
                }
            }
        }
        .atumDesign(design)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(status == .sending)
        .sensoryFeedback(.success, trigger: status == .sent)
        .onAppear { reasonFocused = true }
        .accessibilityIdentifier("report.sheet")
    }

    private func submit() {
        guard status == .idle else { return }
        status = .sending
        failed = false
        let typed = reason
        Task { @MainActor in
            let sent = await send(ReportPolicy.reason(typed))
            guard sent else {
                status = .idle
                failed = true
                AccessibilityNotification.Announcement(ChatCopy.text(design, .errorGeneric)).post()
                return
            }
            status = .sent
            AccessibilityNotification.Announcement(ChatCopy.text(design, .reportSent)).post()
            try? await Task.sleep(for: .milliseconds(900))
            dismiss()
        }
    }
}
