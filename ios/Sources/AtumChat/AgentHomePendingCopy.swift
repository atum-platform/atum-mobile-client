import Foundation

/// The "where it lives" words the pinned design export does not carry yet,
/// with the exact values of desktop's `agent-home-copy.ts` `words` tables
/// (atum-app `050ede8edf5`), generated from that file for every locale the
/// pin supports, so Japanese and Chinese never fall back to English (D-8).
/// The app asks the pin for `src.matrix.agent-home-copy.words.<rawValue>`
/// first; these answer until the next `export:mobile` pin carries the key.
/// Nothing here is hand-edited into `ios/Vendor/AtumDesign`.
public enum AgentHomePendingCopy {
    public enum Key: String, CaseIterable, Sendable {
        case finding = "finding"
        case unknownPlace = "unknownPlace"
        case retryRead = "retryRead"
        case unavailableFallback = "unavailableFallback"
        case unavailableOffline = "unavailableReasons.offline"
        case unavailableVersionUnsupported = "unavailableReasons.version_unsupported"
        case unavailableHomeConflict = "unavailableReasons.home_conflict"
        case unavailableCatalog = "unavailableReasons.catalog_unavailable"
        case readinessAsleep = "readinessAsleep"
        case readinessUnavailable = "readinessUnavailable"
        case acceptCheckpointLoss = "acceptCheckpointLoss"
        case lastCheckpoint = "lastCheckpoint"
        case unnamedMac = "place"
        case refusalTargetUnavailable = "refusals.target_unavailable"
        case refusalConnectionUnavailable = "refusals.connection_unavailable"
        case refusalCatalogStale = "refusals.catalog_stale"
        case refusalNotEligible = "refusals.not_eligible"
        case refusalUnknownExportClass = "refusals.unknown_export_class"
        case refusalCloudVersion = "refusals.cloud_controller_version_unsupported"
        case refusalModelUnavailable = "refusals.model_unavailable"
        case refusalCurrentHomeUnreachable = "refusals.current_home_unreachable"
        case issueTargetUnavailable = "issues.target_unavailable"
        case endedFallback = "endedFallback"
    }

    private static let tables: [String: [Key: String]] = [
        "en": [
            .finding: "Finding where it lives…",
            .unknownPlace: "Couldn’t tell where it lives yet.",
            .retryRead: "Try again",
            .unavailableFallback: "Unavailable",
            .unavailableOffline: "Offline",
            .unavailableVersionUnsupported: "Needs an update",
            .unavailableHomeConflict: "Busy",
            .unavailableCatalog: "No models yet",
            .readinessAsleep: "Asleep",
            .readinessUnavailable: "Not reachable",
            .acceptCheckpointLoss: "I accept losing changes since this checkpoint",
            .lastCheckpoint: "Last checkpoint: %1$@",
            .unnamedMac: "Another Mac",
            .refusalTargetUnavailable: "That place isn't available right now.",
            .refusalConnectionUnavailable: "That model's connection isn't available right now.",
            .refusalCatalogStale: "That Mac's models are out of date. Open Atum on it, then try again.",
            .refusalNotEligible: "It can't move there right now.",
            .refusalUnknownExportClass: "Some of its data can't be moved safely yet.",
            .refusalCloudVersion: "Moving to or from the cloud needs an update first.",
            .refusalModelUnavailable: "That model isn't available there right now.",
            .refusalCurrentHomeUnreachable: "Its Mac isn't answering right now. Wait for it, or move to the cloud.",
            .issueTargetUnavailable: "The other Mac did not take over in time, so the move was called off. It stays here.",
            .endedFallback: "The last move did not finish, so it stays where it was.",
        ],
        "vi": [
            .finding: "Đang xác định vị trí…",
            .unknownPlace: "Chưa xác định được vị trí.",
            .retryRead: "Thử lại",
            .unavailableFallback: "Chưa thể chuyển",
            .unavailableOffline: "Ngoại tuyến",
            .unavailableVersionUnsupported: "Cần cập nhật",
            .unavailableHomeConflict: "Đang bận",
            .unavailableCatalog: "Chưa có mô hình",
            .readinessAsleep: "Đang ngủ",
            .readinessUnavailable: "Chưa kết nối được",
            .acceptCheckpointLoss: "Tôi chấp nhận mất thay đổi kể từ điểm lưu này",
            .lastCheckpoint: "Điểm lưu gần nhất: %1$@",
            .unnamedMac: "Một máy Mac khác",
            .refusalTargetUnavailable: "Nơi đó hiện chưa sẵn sàng.",
            .refusalConnectionUnavailable: "Kết nối của mô hình đó hiện chưa sẵn sàng.",
            .refusalCatalogStale: "Danh sách mô hình trên máy Mac đó đã cũ. Hãy mở Atum trên máy đó rồi thử lại.",
            .refusalNotEligible: "Hiện chưa thể chuyển trợ lý đến đó.",
            .refusalUnknownExportClass: "Một số dữ liệu chưa thể chuyển an toàn.",
            .refusalCloudVersion: "Cần cập nhật trước khi chuyển đến hoặc đi từ đám mây.",
            .refusalModelUnavailable: "Mô hình đó hiện chưa dùng được ở đó.",
            .refusalCurrentHomeUnreachable: "Máy Mac của trợ lý hiện chưa phản hồi. Hãy chờ máy đó, hoặc chuyển lên đám mây.",
            .issueTargetUnavailable: "Máy kia chưa tiếp nhận kịp nên việc chuyển đã bị hủy. Trợ lý vẫn ở lại đây.",
            .endedFallback: "Lần chuyển vừa rồi chưa xong, nên trợ lý vẫn ở nơi cũ.",
        ],
        "ja": [
            .finding: "場所を確認しています…",
            .unknownPlace: "場所を確認できませんでした。",
            .retryRead: "もう一度試す",
            .unavailableFallback: "利用できません",
            .unavailableOffline: "オフライン",
            .unavailableVersionUnsupported: "アップデートが必要",
            .unavailableHomeConflict: "使用中",
            .unavailableCatalog: "モデルなし",
            .readinessAsleep: "スリープ中",
            .readinessUnavailable: "現在接続できません",
            .acceptCheckpointLoss: "このチェックポイント以降の変更が失われることに同意します",
            .lastCheckpoint: "最後のチェックポイント: %1$@",
            .unnamedMac: "別の Mac",
            .refusalTargetUnavailable: "その場所は今ご利用いただけません。",
            .refusalConnectionUnavailable: "そのモデルの接続は今ご利用いただけません。",
            .refusalCatalogStale: "その Mac のモデル情報が古くなっています。その Mac で Atum を開いてから、もう一度お試しください。",
            .refusalNotEligible: "今はそこへ移動できません。",
            .refusalUnknownExportClass: "一部のデータはまだ安全に移動できません。",
            .refusalCloudVersion: "クラウドへの移動、またはクラウドからの移動には、先にアップデートが必要です。",
            .refusalModelUnavailable: "そのモデルは今そこでは使えません。",
            .refusalCurrentHomeUnreachable: "アシスタントがいる Mac が今応答していません。待つか、クラウドへ移動してください。",
            .issueTargetUnavailable: "もう一方の Mac が時間内に引き継げなかったため、移動を取りやめました。アシスタントはこのまま残ります。",
            .endedFallback: "前回の移動は完了しなかったため、アシスタントは元の場所に残っています。",
        ],
        "zh": [
            .finding: "正在确认所在位置…",
            .unknownPlace: "暂时无法确认所在位置。",
            .retryRead: "重试",
            .unavailableFallback: "暂不可用",
            .unavailableOffline: "离线",
            .unavailableVersionUnsupported: "需要更新",
            .unavailableHomeConflict: "忙碌中",
            .unavailableCatalog: "暂无模型",
            .readinessAsleep: "已休眠",
            .readinessUnavailable: "暂时无法连接",
            .acceptCheckpointLoss: "我接受丢失此检查点之后的更改",
            .lastCheckpoint: "上次检查点：%1$@",
            .unnamedMac: "另一台 Mac",
            .refusalTargetUnavailable: "那个位置目前不可用。",
            .refusalConnectionUnavailable: "该模型的连接目前不可用。",
            .refusalCatalogStale: "那台 Mac 上的模型列表已过期。请先在那台 Mac 上打开 Atum，然后重试。",
            .refusalNotEligible: "目前无法移动到那里。",
            .refusalUnknownExportClass: "部分数据暂时无法安全移动。",
            .refusalCloudVersion: "移动到云端或从云端移出之前，需要先更新。",
            .refusalModelUnavailable: "该模型目前在那里不可用。",
            .refusalCurrentHomeUnreachable: "助手所在的 Mac 目前没有响应。请等待它，或将助手移动到云端。",
            .issueTargetUnavailable: "另一台 Mac 未能及时接手，因此已取消移动。助手仍留在这里。",
            .endedFallback: "上一次移动未完成，助手仍留在原来的位置。",
        ],
        "zh-Hant": [
            .finding: "正在確認所在位置…",
            .unknownPlace: "暫時無法確認所在位置。",
            .retryRead: "再試一次",
            .unavailableFallback: "暫時無法使用",
            .unavailableOffline: "離線",
            .unavailableVersionUnsupported: "需要更新",
            .unavailableHomeConflict: "忙碌中",
            .unavailableCatalog: "暫無模型",
            .readinessAsleep: "已休眠",
            .readinessUnavailable: "暫時無法連線",
            .acceptCheckpointLoss: "我接受遺失此檢查點之後的變更",
            .lastCheckpoint: "上次檢查點：%1$@",
            .unnamedMac: "另一部 Mac",
            .refusalTargetUnavailable: "那個位置目前無法使用。",
            .refusalConnectionUnavailable: "該模型的連線目前無法使用。",
            .refusalCatalogStale: "那部 Mac 上的模型清單已過期。請先在那部 Mac 上開啟 Atum，然後再試一次。",
            .refusalNotEligible: "目前無法移動到那裡。",
            .refusalUnknownExportClass: "部分資料暫時無法安全移動。",
            .refusalCloudVersion: "移動到雲端或從雲端移出之前，需要先更新。",
            .refusalModelUnavailable: "該模型目前在那裡無法使用。",
            .refusalCurrentHomeUnreachable: "助理所在的 Mac 目前沒有回應。請等待它，或將助理移動到雲端。",
            .issueTargetUnavailable: "另一部 Mac 未能及時接手，因此已取消移動。助理仍留在這裡。",
            .endedFallback: "上一次移動未完成，助理仍留在原本的位置。",
        ],
    ]

    public static let locales = ["en", "ja", "vi", "zh", "zh-Hant"]

    /// The export key the pin will carry, or nil where desktop's word is a
    /// function the pin cannot carry as-is (`place("")`, "Another Mac").
    public static func exportKey(_ key: Key) -> String? {
        key == .unnamedMac ? nil : "src.matrix.agent-home-copy.words." + key.rawValue
    }

    /// The pending value in `locale` (English for a locale without a table),
    /// with `argument` in place of `%1$@`.
    public static func text(_ key: Key, locale: String, argument: String? = nil) -> String {
        let template = tables[locale]?[key] ?? tables["en"]?[key] ?? key.rawValue
        guard let argument else { return template }
        return template.replacingOccurrences(of: "%1$@", with: argument)
    }
}
