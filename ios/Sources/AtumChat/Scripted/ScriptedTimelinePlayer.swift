#if DEBUG
import Foundation

/// Plays a `ScriptedScript` the way the SDK would deliver it: ordered diff
/// batches on an index-aligned list, typing changes and back-pagination
/// status. Deterministic and synchronous, so tests drive it with a fake clock;
/// `ScriptedTimelineSource` runs it on real time for the app.
///
/// It keeps its own copy of the SDK list (a `TimelineBuffer`) to compute
/// indices, and places items the way matrix-sdk-ui does as far as the chat's
/// rules depend on it:
/// - a remote event goes above my local echoes still on their way (pending,
///   failed, or sent but not yet replaced by the remote copy);
/// - my echo's remote copy keeps the echo's ID and replaces it in place, or
///   moves above the echoes still below it;
/// - a new day starts with a day divider, and an older page that ends on the
///   loaded content's first day takes over that day's divider;
/// - the room's send queue goes one way after a failure: a recoverable one
///   disables the queue, so every later send stays sending behind it until
///   `enableSendQueue()`; removing or unparking a request does not wake a
///   disabled queue. An unrecoverable failure parks only its own request and
///   the queue goes on;
/// - re-enabling the queue emits nothing: a recoverable failure stays failed
///   until its resend settles (unparking with `retrySend` does show it
///   sending again).
public struct ScriptedTimelinePlayer: Sendable {
    /// What the SDK listeners would report, in order.
    public enum Output: Equatable, Sendable {
        /// One `Timeline.addListener` batch.
        case diffs([ChatDiff])
        /// `Room.subscribeToTypingNotifications`: the user IDs typing now.
        case typing([String])
        /// `Timeline.subscribeToBackPaginationStatus`.
        case pagination(PaginationState)
    }

    /// The remote copy replaces a sent echo this long after the send.
    public static let remoteCopyDelay: TimeInterval = 0.15

    public let script: ScriptedScript
    /// Wall-clock time of the open; event timestamps are `reference + time`.
    public let reference: Date
    public let calendar: Calendar
    /// The player's copy of the SDK list.
    public private(set) var buffer = TimelineBuffer()
    /// Seconds since the open.
    public private(set) var now: TimeInterval = 0
    public private(set) var pagination: PaginationState = .idle(hitTimelineStart: false)
    public private(set) var typingUserIDs: [String] = []
    /// `Room.isSendQueueEnabled()`.
    public private(set) var isSendQueueEnabled = true

    private var queue: [Scheduled] = []
    private var order = 0
    private var pagesServed = 0
    private var sendCount = 0
    private var answerCount = 0
    private var dividerCount = 0
    private var usesDayDividers = false
    /// My sends waiting behind a disabled queue, in queue order: still
    /// sending, nothing scheduled.
    private var held: [String] = []

    private struct Scheduled: Sendable {
        var at: TimeInterval
        var order: Int
        var action: Action
    }

    private enum Action: Sendable {
        case step(ScriptedEvent)
        case settle(itemID: String, Settlement)
        case uploadProgress(itemID: String, Double)
        case remoteCopy(itemID: String)
        case seen(itemID: String)
        case startTyping
        case answer(itemID: String)
        /// A streamed answer grows to its next body.
        case grow(itemID: String, body: String)
        case stopTyping
    }

    private enum Settlement: Sendable {
        case sent
        case failed(isRecoverable: Bool)
    }

    public init(script: ScriptedScript, reference: Date, calendar: Calendar = .current) {
        self.script = script
        self.reference = reference
        self.calendar = calendar
    }

    /// When the next scheduled event is due, in seconds since the open.
    public var nextEventTime: TimeInterval? { queue.first?.at }

    public var hasOlderPages: Bool { pagesServed < script.olderPages.count }

    // MARK: Open and time

    /// The open: the cached items as one `reset` batch, the pagination status,
    /// and the steps scheduled.
    public mutating func open() -> [Output] {
        var initial = script.initial
        usesDayDividers = (script.initial + script.olderPages.joined()).contains {
            if case .dayDivider = $0.kind { true } else { false }
        }
        if usesDayDividers, let first = initial.firstIndex(where: \.kind.isEventContent),
           !initial[..<first].contains(where: { if case .dayDivider = $0.kind { true } else { false } }) {
            initial.insert(divider(for: initial[first].timestamp), at: first)
        }
        let hit = script.olderPages.isEmpty && script.startsAfterOlderPages
        if hit, initial.first?.kind != .timelineStart {
            initial.insert(startItem(), at: 0)
        }
        for step in script.steps {
            schedule(step.at, .step(step.event))
        }
        // A recoverable failure left from an earlier run: the queue is still
        // disabled and my later sends wait behind it.
        if let failed = initial.firstIndex(where: { $0.isLocalEcho && $0.delivery == .failed(isRecoverable: true) }) {
            isSendQueueEnabled = false
            held = initial[(failed + 1)...].filter { $0.isLocalEcho && $0.delivery == .sending() }.map(\.id)
        }
        pagination = .idle(hitTimelineStart: hit)
        return [apply([.reset(initial)]), .pagination(pagination)].compactMap { $0 }
    }

    /// Everything due up to `time`, in order.
    public mutating func advance(to time: TimeInterval) -> [Output] {
        var outputs: [Output] = []
        while let next = queue.first, next.at <= time {
            queue.removeFirst()
            now = max(now, next.at)
            outputs += perform(next.action)
        }
        now = max(now, time)
        return outputs
    }

    // MARK: Commands (at `now`)

    /// `Timeline.send`: my echo appears at once at the bottom, still sending.
    /// Returns its item ID.
    public mutating func send(text: String, replyTo: String? = nil) -> (itemID: String, outputs: [Output]) {
        sendCount += 1
        let id = "\(script.name).send-\(sendCount)"
        let item = ChatItem(id: id, kind: .message, sender: script.context.ownUserID, isOwn: true,
                            isLocalEcho: true, timestamp: date(now), delivery: .sending(),
                            eventOrTransactionId: .transaction("txn-" + id), body: text, replyTo: replyTo)
        var diffs = dividerIfNewDay(for: item, at: buffer.items.count)
        diffs.append(.pushBack(item))
        if !isSendQueueEnabled {
            // The SDK queues it behind the failed head; it waits.
            held.append(id)
        } else {
            switch script.sends {
            case let .succeeds(after): schedule(now + after, .settle(itemID: id, .sent))
            case let .failsRecoverably(after, _): schedule(now + after, .settle(itemID: id, .failed(isRecoverable: true)))
            case let .failsUnrecoverably(after, _): schedule(now + after, .settle(itemID: id, .failed(isRecoverable: false)))
            case .staysSending: break
            }
        }
        return (id, [apply(diffs)].compactMap { $0 })
    }

    public mutating func send(attachment: OutgoingChatAttachment, caption: String?,
                              replyTo: String? = nil) -> (itemID: String, outputs: [Output]) {
        sendCount += 1
        let id = "\(script.name).send-\(sendCount)"
        let kind: ChatItem.Kind = switch attachment.kind {
        case let .image(width, height, _): .image(width: Double(width), height: Double(height))
        case .file: .file(name: attachment.filename)
        }
        let isAnimated: Bool = switch attachment.kind {
        case let .image(_, _, animated): animated
        case .file: false
        }
        let media = ChatMedia(sourceHandle: "scripted:local:" + id,
                              thumbnailSourceHandle: "scripted:thumbnail:local:" + id,
                              mimetype: attachment.mimetype, filename: attachment.filename,
                              isAnimated: isAnimated,
                              byteSize: attachment.byteSize)
        let item = ChatItem(id: id, kind: kind, sender: script.context.ownUserID,
                            isOwn: true, isLocalEcho: true, timestamp: date(now),
                            delivery: .sending(), eventOrTransactionId: .transaction("txn-" + id),
                            body: caption ?? "", media: media, replyTo: replyTo)
        var diffs = dividerIfNewDay(for: item, at: buffer.items.count)
        diffs.append(.pushBack(item))
        if !isSendQueueEnabled {
            held.append(id)
        } else {
            switch script.sends {
            case let .succeeds(after):
                if after > 0.1 { schedule(now + after / 2, .uploadProgress(itemID: id, 0.55)) }
                schedule(now + after, .settle(itemID: id, .sent))
            case let .failsRecoverably(after, _):
                if after > 0.1 { schedule(now + after / 2, .uploadProgress(itemID: id, 0.45)) }
                schedule(now + after, .settle(itemID: id, .failed(isRecoverable: true)))
            case let .failsUnrecoverably(after, _):
                if after > 0.1 { schedule(now + after / 2, .uploadProgress(itemID: id, 0.45)) }
                schedule(now + after, .settle(itemID: id, .failed(isRecoverable: false)))
            case .staysSending: break
            }
        }
        return (id, [apply(diffs)].compactMap { $0 })
    }

    /// `Room.enableSendQueue(enable: true)`: the queue wakes and resends the
    /// room's recoverable failures and everything held behind them, in order
    /// (B8). Parked (unrecoverable) requests are not touched.
    ///
    /// Like the pinned SDK, it emits nothing: re-enabling a queue only wakes
    /// the sending task, and a recoverable failure keeps its
    /// `.sendingFailed` state until the resend settles (the hotfix log's known
    /// limits, from `send_queue/mod.rs` at matrix-rust-sdk `4f7f4d49`). A clock
    /// in that gap would have to come from the store, never from here.
    public mutating func enableSendQueue() -> [Output] {
        isSendQueueEnabled = true
        let waiting = Set(held)
        held = []
        for item in buffer.items where item.delivery == .failed(isRecoverable: true) || waiting.contains(item.id) {
            schedule(now + retryDelay, .settle(itemID: item.id, .sent))
        }
        return []
    }

    /// `Timeline.retrySend`: unparks one failed message and shows it sending
    /// again. It goes out only while the queue is enabled; behind a disabled
    /// queue it waits for `enableSendQueue()`. False when the item is not a
    /// failed send.
    public mutating func retrySend(itemID: String) -> (retried: Bool, outputs: [Output]) {
        guard let index = index(of: itemID), case .failed = buffer.items[index].delivery else { return (false, []) }
        var resent = buffer.items[index]
        resent.delivery = .sending()
        if isSendQueueEnabled {
            schedule(now + retryDelay, .settle(itemID: itemID, .sent))
        } else {
            hold(itemID)
        }
        return (true, [apply([.set(index: index, item: resent)])].compactMap { $0 })
    }

    /// `Timeline.abortSend`: removes a send that has not gone out. False when
    /// the item is not one of my sends still pending or failed. A disabled
    /// queue stays disabled: what waited behind the removed send keeps
    /// waiting.
    public mutating func abortSend(itemID: String) -> (removed: Bool, outputs: [Output]) {
        guard let index = index(of: itemID), buffer.items[index].isLocalEcho else { return (false, []) }
        switch buffer.items[index].delivery {
        case .sending, .failed: break
        case .sent, .remote: return (false, [])
        }
        unschedule(itemID)
        held.removeAll { $0 == itemID }
        return (true, [apply([.remove(index: index)])].compactMap { $0 })
    }

    /// `Timeline.toggleReaction` with my user.
    public mutating func toggleReaction(itemID: String, key: String) -> [Output] {
        guard let index = index(of: itemID) else { return [] }
        var item = buffer.items[index]
        let me = script.context.ownUserID
        if let reaction = item.reactions.firstIndex(where: { $0.key == key }) {
            var senders = item.reactions[reaction].senderIDs
            if let mine = senders.firstIndex(of: me) { senders.remove(at: mine) } else { senders.append(me) }
            if senders.isEmpty {
                item.reactions.remove(at: reaction)
            } else {
                item.reactions[reaction].senderIDs = senders
            }
        } else {
            item.reactions.append(ChatReaction(key: key, senderIDs: [me]))
        }
        return [apply([.set(index: index, item: item)])].compactMap { $0 }
    }

    /// `Timeline.redactEvent`.
    public mutating func redact(itemID: String) -> [Output] {
        perform(.step(.redact(id: itemID)))
    }

    /// `Timeline.edit`.
    public mutating func edit(itemID: String, text: String) -> [Output] {
        perform(.step(.edit(id: itemID, body: text)))
    }

    /// `paginateBackwards` begins: the status turns to `paginating`, unless
    /// the start is already reached.
    public mutating func beginPagination() -> [Output] {
        guard hasOlderPages else { return [] }
        pagination = .paginating
        return [.pagination(pagination)]
    }

    /// `paginateBackwards` ends: the next older page lands above. Returns
    /// whether the start of the room is reached (the call's return value).
    public mutating func servePage() -> (outputs: [Output], hitTimelineStart: Bool) {
        guard hasOlderPages else {
            let hit = script.startsAfterOlderPages
            pagination = .idle(hitTimelineStart: hit)
            return ([.pagination(pagination)], hit)
        }
        var page = script.olderPages[pagesServed]
        pagesServed += 1
        if usesDayDividers, let first = page.first(where: \.kind.isEventContent),
           !isDivider(page.first) {
            page.insert(divider(for: first.timestamp), at: 0)
        }
        var diffs: [ChatDiff] = page.reversed().map { .pushFront($0) }
        // The loaded content's first day now starts inside the page: its old
        // divider goes, as the SDK's date-divider adjuster does.
        if let oldFirst = buffer.items.first, case let .dayDivider(day) = oldFirst.kind,
           let lastEvent = page.last(where: \.kind.isEventContent),
           calendar.isDate(day, inSameDayAs: lastEvent.timestamp) {
            diffs.append(.remove(index: page.count))
        }
        let hit = !hasOlderPages && script.startsAfterOlderPages
        if hit { diffs.append(.pushFront(startItem())) }
        pagination = .idle(hitTimelineStart: hit)
        return ([apply(diffs), .pagination(pagination)].compactMap { $0 }, hit)
    }

    // MARK: Performing

    private mutating func perform(_ action: Action) -> [Output] {
        switch action {
        case let .step(event):
            return perform(event)

        case let .settle(itemID, settlement):
            guard let index = index(of: itemID) else { return [] }
            var item = buffer.items[index]
            switch settlement {
            case .sent:
                item.delivery = .sent(eventID: "$" + itemID)
                schedule(now + Self.remoteCopyDelay, .remoteCopy(itemID: itemID))
            case let .failed(isRecoverable):
                item.delivery = .failed(isRecoverable: isRecoverable)
                if isRecoverable { disableSendQueue(after: itemID) }
            }
            return [apply([.set(index: index, item: item)])].compactMap { $0 }

        case let .uploadProgress(itemID, fraction):
            guard let index = index(of: itemID) else { return [] }
            var item = buffer.items[index]
            guard case .sending = item.delivery else { return [] }
            item.delivery = .sending(progress: fraction)
            return [apply([.set(index: index, item: item)])].compactMap { $0 }

        case let .remoteCopy(itemID):
            guard let index = index(of: itemID) else { return [] }
            var item = buffer.items[index]
            item.delivery = .remote
            item.isLocalEcho = false
            item.eventOrTransactionId = .event("$" + itemID)
            let below = buffer.items[(index + 1)...]
            let diffs: [ChatDiff]
            if below.allSatisfy({ isPendingEcho($0) || $0.kind.isVirtual }) {
                diffs = [.set(index: index, item: item)]
            } else {
                var rest = buffer.items
                rest.remove(at: index)
                diffs = [.remove(index: index), .insert(index: remoteInsertionIndex(in: rest), item: item)]
            }
            scheduleReplies(to: itemID)
            return [apply(diffs)].compactMap { $0 }

        case let .seen(itemID):
            guard let replies = script.replies else { return [] }
            return perform(.receipt(userID: replies.sender, onItemID: itemID))

        case .startTyping:
            guard let replies = script.replies else { return [] }
            return perform(.typing([replies.sender]))

        case let .answer(itemID):
            guard let replies = script.replies, !replies.bodies.isEmpty else { return [] }
            let body = replies.bodies[answerCount % replies.bodies.count]
            answerCount += 1
            let id = "\(script.name).answer-\(answerCount)"
            let replyTo = replies.answersAsReply ? "$" + itemID : nil
            var answer = ChatItem(id: id, kind: .message, sender: replies.sender,
                                  senderName: script.names[replies.sender],
                                  eventOrTransactionId: .event("$" + id), body: body, replyTo: replyTo,
                                  resultFor: ChatItem.resultFor(kind: .message, sender: replies.sender,
                                                                replyTo: replyTo,
                                                                agentUserIDs: script.context.agentUserIDs))
            if let stream = replies.stream, let first = stream.bodies.first {
                answer.body = first
                for (index, grown) in stream.bodies.dropFirst().enumerated() {
                    schedule(now + stream.every * Double(index + 1), .grow(itemID: id, body: grown))
                }
                schedule(now + stream.every * Double(stream.bodies.count), .stopTyping)
                return perform(.arrive(answer))
            }
            var outputs = perform(.arrive(answer))
            if replies.typingAfter != nil, typingUserIDs.contains(replies.sender) {
                outputs += perform(.typing(typingUserIDs.filter { $0 != replies.sender }))
            }
            return outputs

        case let .grow(itemID, body):
            return perform(.edit(id: itemID, body: body))

        case .stopTyping:
            guard let replies = script.replies, typingUserIDs.contains(replies.sender) else { return [] }
            return perform(.typing(typingUserIDs.filter { $0 != replies.sender }))
        }
    }

    private mutating func perform(_ event: ScriptedEvent) -> [Output] {
        switch event {
        case let .arrive(value):
            var item = value
            item.timestamp = date(now)
            item.isLocalEcho = false
            item.delivery = .remote
            item.isOwn = item.sender == script.context.ownUserID
            if item.eventOrTransactionId == nil { item.eventOrTransactionId = .event("$" + item.id) }
            let at = remoteInsertionIndex(in: buffer.items)
            var diffs = dividerIfNewDay(for: item, at: at)
            let position = at + diffs.count
            diffs.append(position == buffer.items.count + diffs.count
                         ? .pushBack(item) : .insert(index: position, item: item))
            return [apply(diffs)].compactMap { $0 }

        case let .edit(id, body):
            guard let index = index(of: id) else { return [] }
            var item = buffer.items[index]
            item.body = body
            item.isEdited = true
            return [apply([.set(index: index, item: item)])].compactMap { $0 }

        case let .editNotice(id, body, appBotMeta):
            guard let index = index(of: id) else { return [] }
            var item = buffer.items[index]
            item.body = body
            item.appBotMeta = appBotMeta
            item.isEdited = true
            return [apply([.set(index: index, item: item)])].compactMap { $0 }

        case let .receipt(userID, onItemID):
            guard let target = index(of: onItemID) else { return [] }
            var diffs: [ChatDiff] = []
            for (index, item) in buffer.items.enumerated() where index != target && item.receiptUserIDs.contains(userID) {
                var moved = item
                moved.receiptUserIDs.removeAll { $0 == userID }
                diffs.append(.set(index: index, item: moved))
            }
            var item = buffer.items[target]
            if !item.receiptUserIDs.contains(userID) {
                item.receiptUserIDs = (item.receiptUserIDs + [userID]).sorted()
                diffs.append(.set(index: target, item: item))
            }
            return [apply(diffs)].compactMap { $0 }

        case let .typing(userIDs):
            typingUserIDs = userIDs
            return [.typing(userIDs)]

        case let .redact(id):
            guard let index = index(of: id) else { return [] }
            var item = buffer.items[index]
            item.kind = .placeholder(.redacted)
            item.body = ""
            item.isEdited = false
            item.replyTo = nil
            item.resultFor = nil
            item.reactions = []
            return [apply([.set(index: index, item: item)])].compactMap { $0 }
        }
    }

    private mutating func scheduleReplies(to itemID: String) {
        guard let replies = script.replies else { return }
        schedule(now + replies.seenAfter, .seen(itemID: itemID))
        if let typingAfter = replies.typingAfter { schedule(now + typingAfter, .startTyping) }
        if let answerAfter = replies.answerAfter { schedule(now + answerAfter, .answer(itemID: itemID)) }
    }

    // MARK: Helpers

    private var retryDelay: TimeInterval {
        switch script.sends {
        case let .failsRecoverably(_, retryAfter), let .failsUnrecoverably(_, retryAfter): return retryAfter
        case let .succeeds(after): return after
        case .staysSending: return 0.3
        }
    }

    /// A recoverable failure disables the room's queue: my other sends still
    /// going out stop where they are and wait, sending.
    private mutating func disableSendQueue(after failedItemID: String) {
        isSendQueueEnabled = false
        var waiting: [String] = []
        queue.removeAll { entry in
            guard case let .settle(id, _) = entry.action, id != failedItemID else { return false }
            waiting.append(id)
            return true
        }
        for id in waiting { hold(id) }
    }

    /// Adds my send to the held list, keeping the list in buffer order.
    private mutating func hold(_ itemID: String) {
        guard !held.contains(itemID) else { return }
        held.append(itemID)
        let order = Dictionary(uniqueKeysWithValues: buffer.items.enumerated().map { ($1.id, $0) })
        held.sort { (order[$0] ?? .max) < (order[$1] ?? .max) }
    }

    private mutating func unschedule(_ itemID: String) {
        queue.removeAll {
            if case let .settle(id, _) = $0.action { return id == itemID }
            return false
        }
    }

    private mutating func schedule(_ at: TimeInterval, _ action: Action) {
        order += 1
        let entry = Scheduled(at: at, order: order, action: action)
        let index = queue.firstIndex { ($0.at, $0.order) > (entry.at, entry.order) } ?? queue.count
        queue.insert(entry, at: index)
    }

    /// Applies one batch to the player's copy of the SDK list. A scenario
    /// whose indices do not fit is a bug in the scenario.
    private mutating func apply(_ diffs: [ChatDiff]) -> Output? {
        guard !diffs.isEmpty else { return nil }
        do {
            try buffer.apply(diffs)
        } catch {
            assertionFailure("scripted scenario \(script.name) produced an out-of-range batch: \(error)")
            return nil
        }
        return .diffs(diffs)
    }

    private func index(of itemID: String) -> Int? {
        buffer.items.firstIndex { $0.id == itemID }
    }

    // MARK: Plain-value lookups (`ChatTimelineSource`)

    /// The item a store's `ChatEventRef` names: by its event or transaction
    /// ID, or by the event ID an accepted echo's `.sent` state carries.
    public func itemID(for ref: ChatEventRef) -> String? {
        buffer.items.first { item in
            if item.eventOrTransactionId == ref { return true }
            if case let .event(eventID) = ref { return item.eventID == eventID }
            return false
        }?.id
    }

    /// B21: what the SDK's `InReplyToDetails` would say for an item that
    /// replies to an event: ready when the original is in the list (with the
    /// same reduced preview a quote draws), unavailable otherwise (scripted
    /// rooms never fetch). Nil for an item that replies to nothing.
    public func replyDetails(for item: ChatItem) -> ChatReplyDetails? {
        guard let replyTo = item.replyTo else { return nil }
        guard let original = buffer.items.first(where: { $0.eventID == replyTo }) else {
            return ChatReplyDetails(eventID: replyTo, state: .unavailable)
        }
        return ChatReplyDetails(eventID: replyTo,
                                state: .ready(sender: original.sender, senderName: original.senderName,
                                              preview: ReplyPreview(kind: original.kind, body: original.body)))
    }

    /// Mine, from this device, not yet replaced by the remote copy.
    private func isPendingEcho(_ item: ChatItem) -> Bool {
        item.isLocalEcho && item.delivery != .remote
    }

    /// Remote events go above the trailing run of my echoes still on their way.
    private func remoteInsertionIndex(in items: [ChatItem]) -> Int {
        var index = items.count
        while index > 0, isPendingEcho(items[index - 1]) { index -= 1 }
        return index
    }

    /// A divider before `position` when the item starts a new day. The
    /// nearest event or divider above decides, so a divider already there
    /// for this day (one my pending echo brought just after midnight) is not
    /// doubled.
    private mutating func dividerIfNewDay(for item: ChatItem, at position: Int) -> [ChatDiff] {
        guard usesDayDividers else { return [] }
        let previous = buffer.items[..<position].last { $0.kind.isEventContent || isDivider($0) }
        if let previous {
            let day: Date
            if case let .dayDivider(dividerDay) = previous.kind { day = dividerDay } else { day = previous.timestamp }
            if calendar.isDate(day, inSameDayAs: item.timestamp) { return [] }
        }
        let divider = divider(for: item.timestamp)
        return [position == buffer.items.count ? .pushBack(divider) : .insert(index: position, item: divider)]
    }

    private mutating func divider(for date: Date) -> ChatItem {
        dividerCount += 1
        let day = calendar.startOfDay(for: date)
        return ChatItem(id: "\(script.name).day-split-\(dividerCount)", kind: .dayDivider(day), timestamp: day)
    }

    private func startItem() -> ChatItem {
        ChatItem(id: "\(script.name).start", kind: .timelineStart)
    }

    private func isDivider(_ item: ChatItem?) -> Bool {
        if case .dayDivider? = item?.kind { return true }
        return false
    }

    private func date(_ time: TimeInterval) -> Date {
        reference.addingTimeInterval(time)
    }
}
#endif
