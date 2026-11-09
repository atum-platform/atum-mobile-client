import Foundation

/// Words the phone owns for the placement sheet's "not set up" and "waiting for
/// the Mac" states, in all five languages the app speaks (en, vi, ja, zh, zh-Hant).
///
/// Most of the sheet's words are still phone-owned fallbacks pending the atum-app
/// export and only carry English and Vietnamese. These do not wait: a Mac that is
/// not set up for the assistant, and a Mac that is not answering, are states the
/// owner has to be able to act on in their own language. The desktop sheet has the
/// same sentences (`apps/desktop/src/matrix/agent-home-copy.ts`); promoting them to
/// the shared export is a follow-up that lets this table be dropped.
public enum AgentHomePlacementCopy {
    public enum Key: String, CaseIterable, Sendable {
        /// Under a Mac the platform does not list as ready: it has no active set-up
        /// for this assistant (or it lapsed), and only that Mac can fix it.
        case openAtumOnMac
        /// The assistant's Mac is not answering. `%1$@` is the Mac's name.
        case waitingForHome
        /// The short form of the same, beside the Mac's row. `%1$@` is the Mac's name.
        case waitingForMac
        /// A move to a Mac was refused because it has no active set-up for the
        /// assistant: the platform says `target_unavailable`, this client says it plainly.
        case macNotSetUp
    }

    public static let locales: [String] = ["en", "ja", "vi", "zh", "zh-Hant"]

    private static let tables: [String: [Key: String]] = [
        "en": [
            .openAtumOnMac: "Open Atum on this Mac to set it up",
            .waitingForHome: "%1$@ isn’t answering right now, so Atum waits for it. If you’d rather not wait, you can move to the cloud. You may lose any changes made since its last checkpoint.",
            .waitingForMac: "Waiting for %1$@",
            .macNotSetUp: "That Mac isn’t set up for this assistant yet. Open Atum on it to set it up, then try again.",
        ],
        "vi": [
            .openAtumOnMac: "Mở Atum trên máy Mac này để thiết lập",
            .waitingForHome: "%1$@ hiện chưa phản hồi nên Atum đang chờ máy này. Nếu không muốn chờ, bạn có thể chuyển trợ lý lên đám mây. Các thay đổi kể từ điểm lưu gần nhất có thể bị mất.",
            .waitingForMac: "Đang chờ %1$@",
            .macNotSetUp: "Máy Mac đó chưa được thiết lập cho trợ lý này. Hãy mở Atum trên máy đó để thiết lập, rồi thử lại.",
        ],
        "ja": [
            .openAtumOnMac: "この Mac で Atum を開いて設定してください",
            .waitingForHome: "%1$@ が今応答していないため、Atum は待機しています。待ちたくない場合は、クラウドへ移動できます。その場合、最後のチェックポイント以降の変更は失われることがあります。",
            .waitingForMac: "%1$@ を待っています",
            .macNotSetUp: "その Mac は、まだこのアシスタント用に設定されていません。その Mac で Atum を開いて設定してから、もう一度お試しください。",
        ],
        "zh": [
            .openAtumOnMac: "请在这台 Mac 上打开 Atum 完成设置",
            .waitingForHome: "%1$@ 目前没有响应，Atum 正在等待。如果不想等待，可以将助手移动到云端，自上一个检查点以来的更改可能会丢失。",
            .waitingForMac: "正在等待 %1$@",
            .macNotSetUp: "那台 Mac 尚未为这个助手设置。请在那台 Mac 上打开 Atum 完成设置，然后重试。",
        ],
        "zh-Hant": [
            .openAtumOnMac: "請在這部 Mac 上開啟 Atum 完成設定",
            .waitingForHome: "%1$@ 目前沒有回應，Atum 正在等待。如果不想等待，可以將助理移動到雲端，自上一個檢查點以來的變更可能會遺失。",
            .waitingForMac: "正在等待 %1$@",
            .macNotSetUp: "那部 Mac 尚未為這個助理設定。請在那部 Mac 上開啟 Atum 完成設定，然後再試一次。",
        ],
    ]

    /// The words for `key` in `locale` (English for a locale it does not know),
    /// with the Mac's `name` where the text has a place for it.
    public static func text(_ key: Key, locale: String, name: String = "") -> String {
        let table = tables[locale] ?? tables.first(where: { $0.key.lowercased() == locale.lowercased() })?.value
            ?? tables["en"]!
        let template = table[key] ?? tables["en"]![key]!
        return template.replacingOccurrences(of: "%1$@", with: name)
    }
}
