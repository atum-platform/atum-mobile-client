#if DEBUG
import Foundation

/// The synthetic people of every scenario. The `.test` top-level domain is
/// reserved, so none of these can be a real account. The bots use the
/// official localparts so the phone's bot rules recognise them.
public enum ScriptedCast {
    public static let me = "@ban:atum.test"
    public static let atum = "@atum:atum.test"
    public static let writer = "@viet-giup:atum.test"
    public static let luna = "@luna:atum.test"
    public static let analyst = "@nha-phan-tich:atum.test"
    public static let minhAnh = "@minh-anh:atum.test"
    public static let minh = "@minh:atum.test"
    public static let lan = "@lan:atum.test"
    public static let hoa = "@hoa:atum.test"
    public static let tuan = "@tuan:atum.test"
    public static let chiMai = "@chi-mai:atum.test"
    public static let anhKhoa = "@anh-khoa:atum.test"
    public static let huy = "@huy:atum.test"
    public static let quan = "@quan:atum.test"
    public static let moon = "@app-moon:atum.test"
    public static let andy = "@app-andy:atum.test"

    public static let names: [String: String] = [
        atum: "Atum", writer: "Viết Giúp", luna: "Luna", analyst: "Nhà phân tích",
        minhAnh: "Minh Anh", minh: "Minh", lan: "Lan", hoa: "Hoa", tuan: "Tuấn",
        chiMai: "Chị Mai", anhKhoa: "Anh Khoa", huy: "Huy", quan: "Quân",
        moon: "Moon", andy: "Andy"
    ]

    /// Synthetic catalog app IDs (UUID v4 shape, as desktop requires).
    public static let moonAppID = "00000000-0000-4000-8000-00000000a001"
    public static let andyAppID = "00000000-0000-4000-8000-00000000a002"
}

/// Writes a transcript in order: fixed IDs (`<scenario>.0001`), event IDs
/// (`$` + ID), a day divider whenever the day changes, `isOwn` and
/// `resultFor` from the room context. Scripted IDs are fixed so UI tests can
/// query `row.<id>`.
struct ScriptedWriter {
    let scenario: String
    let context: RoomContext
    let calendar: Calendar
    private(set) var items: [ChatItem] = []
    private var count = 0

    init(scenario: String, context: RoomContext, calendar: Calendar) {
        self.scenario = scenario
        self.context = context
        self.calendar = calendar
    }

    /// The last event written, for replies.
    var last: ChatItem? { items.last { $0.kind.isEventContent } }

    @discardableResult
    mutating func add(_ kind: ChatItem.Kind = .message, from sender: String, at date: Date, body: String = "",
                      media: ChatMedia? = nil,
                      replyTo: String? = nil, threadRoot: String? = nil, reactions: [ChatReaction] = [],
                      receipts: [String] = [], isEdited: Bool = false, delivery: ChatDelivery = .remote,
                      appBotMeta: String? = nil) -> ChatItem {
        if kind.isEventContent { dividerIfNewDay(date) }
        count += 1
        let id = scenario + "." + String(format: "%04d", count)
        let isLocalEcho = delivery != .remote
        let item = ChatItem(id: id, kind: kind, sender: sender, senderName: ScriptedCast.names[sender],
                            isOwn: sender == context.ownUserID, isLocalEcho: isLocalEcho, timestamp: date,
                            delivery: delivery,
                            eventOrTransactionId: isLocalEcho ? .transaction("txn-" + id) : .event("$" + id),
                            body: body, media: media, isEdited: isEdited, replyTo: replyTo, threadRoot: threadRoot,
                            reactions: reactions, receiptUserIDs: receipts.sorted(),
                            resultFor: ChatItem.resultFor(kind: kind, sender: sender, replyTo: replyTo,
                                                          agentUserIDs: context.agentUserIDs),
                            appBotMeta: appBotMeta)
        items.append(item)
        return item
    }

    mutating func readMarker() {
        count += 1
        items.append(ChatItem(id: scenario + "." + String(format: "%04d", count), kind: .readMarker))
    }

    mutating func start() {
        items.append(ChatItem(id: scenario + ".start", kind: .timelineStart))
    }

    private mutating func dividerIfNewDay(_ date: Date) {
        if let last, calendar.isDate(last.timestamp, inSameDayAs: date) { return }
        let day = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let id = scenario + ".day-" + String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        items.append(ChatItem(id: id, kind: .dayDivider(day), timestamp: day))
    }
}

/// A small deterministic generator, so long scenarios are the same on every
/// run and every machine.
struct ScriptedRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }

    mutating func pick<T>(_ values: [T]) -> T { values[next(values.count)] }
}

/// Synthetic Vietnamese text: invented, generic, mixed lengths.
enum ScriptedText {
    static let questions = [
        "Tóm tắt giúp mình cuộc họp sáng nay nhé.",
        "Lịch tuần sau của mình có gì?",
        "Viết giúp mình một email ngắn cảm ơn đối tác.",
        "Giải thích đoạn mã này giúp mình.",
        "Gợi ý ba quán cà phê yên tĩnh để làm việc.",
        "Nhắc mình gọi cho kế toán lúc 3 giờ chiều.",
        "Dịch câu này sang tiếng Anh: Hẹn gặp lại vào thứ Sáu.",
        "So sánh hai phương án này giúp mình.",
        "Kế hoạch chạy bộ tuần này thế nào?",
        "Có cách nào sắp xếp hộp thư gọn hơn không?",
        "Ok, cảm ơn nhé.",
        "Còn gì nữa không?"
    ]

    static let sentences = [
        "Mình đã xem qua và có vài ý chính.",
        "Phần đầu tập trung vào ngân sách quý tới.",
        "Nhóm thống nhất dời buổi duyệt sang thứ Năm.",
        "Bạn nên ưu tiên việc gấp trước giờ trưa.",
        "Có hai rủi ro cần theo dõi trong tuần này.",
        "Mình đề xuất chia công việc thành ba bước nhỏ.",
        "Thời gian dự kiến khoảng bốn mươi lăm phút.",
        "Nếu cần, mình có thể soạn sẵn bản nháp.",
        "Phương án thứ hai rẻ hơn nhưng chậm hơn một chút.",
        "Bạn nhớ mang theo laptop và sạc dự phòng.",
        "Tài liệu tham khảo nằm trong thư mục chung.",
        "Mình sẽ nhắc lại vào sáng mai."
    ]

    static func paragraph(_ random: inout ScriptedRandom, sentences count: Int) -> String {
        (0..<count).map { _ in random.pick(sentences) }.joined(separator: " ")
    }

    static func list(_ random: inout ScriptedRandom, items count: Int) -> String {
        (1...count).map { "\($0). " + random.pick(sentences) }.joined(separator: "\n")
    }

    /// A fenced code block of about `lines` lines.
    static func code(lines: Int) -> String {
        var body = ["Đây là đoạn mã:", "", "```swift", "func tong(_ cacSo: [Int]) -> Int {"]
        for index in 0..<max(lines - 4, 1) {
            body.append("    let buoc\(index) = cacSo.prefix(\(index + 1)).reduce(0, +)")
        }
        body += ["    return cacSo.reduce(0, +)", "}", "```"]
        return body.joined(separator: "\n")
    }
}
#endif
