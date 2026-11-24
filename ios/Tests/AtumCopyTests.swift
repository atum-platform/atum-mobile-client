import XCTest
@testable import AtumDesign

final class AtumCopyTests: XCTestCase {
    func testEveryCommittedPlainStringRemainsLiteral() throws {
        let copy = try AtumCopy()
        let raw = try JSONSerialization.jsonObject(with: AtumDesign.data(for: "Localizable.xcstrings")) as! [String: Any]
        let strings = raw["strings"] as! [String: [String: Any]]
        let contract = try JSONSerialization.jsonObject(with: AtumDesign.data(for: "copy-contract.json")) as! [String: Any]
        let parameters = contract["parameters"] as! [String: [[String: Any]]]
        for (key, signature) in parameters where signature.isEmpty {
            let localizations = strings[key]!["localizations"] as! [String: [String: Any]]
            for locale in copy.locales {
                let expected = (localizations[locale]!["stringUnit"] as! [String: String])["value"]!
                XCTAssertEqual(try copy.text(key, locale: locale), expected)
            }
        }
    }

    func testParameterKindsFollowTheContract() throws {
        let copy = try AtumCopy()
        XCTAssertEqual(copy.parameterKinds("shared.matrix-team-space-copy.copy.inviteLinkUsage"), ["number", "number"])
        XCTAssertEqual(copy.parameterKinds("src.matrix.assistant-card.copy.assistantCardCopies.routineMonthlyWords"),
                       ["number", "string"])
        XCTAssertNil(copy.parameterKinds("no.such.key"))
    }

    func testCommittedPhoneSourceLoadsExactlyInAllLocales() throws {
        let copy = try AtumCopy()
        let raw = try JSONSerialization.jsonObject(with: AtumDesign.data(for: "Localizable.xcstrings")) as! [String: Any]
        let strings = raw["strings"] as! [String: [String: Any]]
        let keys = strings.keys.filter { $0.hasPrefix("src.matrix.mobile-device-copy.mobileDeviceCopy.") }
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            let localizations = strings[key]!["localizations"] as! [String: [String: Any]]
            for locale in copy.locales {
                let expected = (localizations[locale]!["stringUnit"] as! [String: String])["value"]!
                XCTAssertEqual(try copy.text(key, locale: locale), expected, "\(locale): \(key)")
            }
        }
    }

    func testExactNumericBranchesAndLiteralPercentPreserveSource() throws {
        let copy = try AtumCopy()
        for locale in copy.locales {
            for count: Int64 in [0, 1, 2, 42, 12345] {
                let text = try copy.text("desktop.atum.agents.photoUploading", locale: locale, arguments: [.number(count)])
                XCTAssertTrue(text.contains("\(count)%"), "\(locale), \(count): \(text)")
            }
        }
    }

    func testTeamSpaceInviteCountsUsePinnedPluralRoots() throws {
        let copy = try AtumCopy()
        let cases = [
            ("shared.matrix-team-space-copy.copy.inviteLinkCapacity",
             ["Up to 0 people can use it.", "One person can use it.", "Up to 2 people can use it."]),
            ("shared.matrix-team-space-copy.copy.inviteLinkDuration",
             ["Works for 0 days.", "Works for 1 day.", "Works for 2 days."]),
            ("shared.matrix-team-space-copy.copy.inviteLinkExpires",
             ["expires today", "expires in 1 day", "expires in 2 days"]),
        ]
        for (key, english) in cases {
            for (count, expected) in english.enumerated() {
                let arguments: [AtumCopy.Argument] = [.number(Int64(count))]
                for locale in copy.locales {
                    let value = try copy.text(key, locale: locale, arguments: arguments)
                    if locale == "en" {
                        XCTAssertEqual(value, expected, key)
                    } else {
                        XCTAssertFalse(value.isEmpty, "\(key), \(locale), \(count)")
                    }
                }
            }
        }
    }

    func testScheduledRelayUsagePreservesDesktopCopy() throws {
        let copy = try AtumCopy()
        let key = "src.matrix.mobile-copy.mobileScreensCopy.relay.usageScheduled"
        XCTAssertEqual(copy.parameterKinds(key), ["number"])
        for locale in copy.locales {
            let suffix = locale == "vi" ? "lượt chạy theo lịch" : "scheduled runs"
            for runs: Int64 in [0, 1, 3] {
                XCTAssertEqual(try copy.text(key, locale: locale, arguments: [.number(runs)]),
                               "\(runs) \(suffix)", "\(locale), \(runs)")
            }
        }
    }

    func testPauseHintUsesDesktopCopyInAllLocales() throws {
        let copy = try AtumCopy()
        let key = "shared.matrix-agent-desk-copy.matrixAgentDeskCopy.pauseHint"
        let expected = [
            "en": "Still answers you. Starts nothing on its own.",
            "vi": "Vẫn trả lời bạn. Không tự bắt đầu việc gì.",
            "ja": "返信は続けます。自分から作業は始めません。",
            "zh": "仍会回复你，但不会自行开始任何事。",
            "zh-Hant": "仍會回覆你，但不會自行開始任何事。",
        ]
        XCTAssertEqual(copy.locales, Set(expected.keys))
        XCTAssertEqual(copy.parameterKinds(key), [])
        for (locale, value) in expected {
            XCTAssertEqual(try copy.text(key, locale: locale), value, locale)
        }
    }

    func testConnectionsMacNamesPreserveDesktopFormattingAndFallbacks() throws {
        let copy = try AtumCopy()
        let prefix = "src.matrix.mobile-copy.mobileScreensCopy.connections."
        let macs = "MacBook Air, Mac mini"
        let cases = [
            ("onMacs", "On \(macs)", "Trên \(macs)"),
            ("lastSeen", "Last seen on \(macs)", "Lần cuối trên \(macs)"),
        ]
        for (name, english, vietnamese) in cases {
            let key = prefix + name
            XCTAssertEqual(copy.parameterKinds(key), ["string"])
            for locale in copy.locales {
                XCTAssertEqual(try copy.text(key, locale: locale, arguments: [.text(macs)]),
                               locale == "vi" ? vietnamese : english, "\(name), \(locale)")
            }
        }
    }

    func testTeamSpaceRevampLabelsUseDesktopCopyInAllLocales() throws {
        let copy = try AtumCopy()
        let prefix = "src.matrix.team-space.revamp-copy.copy."
        let locales = ["en", "vi", "ja", "zh", "zh-Hant"]
        let cases: [(name: String, values: [String])] = [
            ("search", ["Search", "Tìm kiếm", "検索", "搜索", "搜尋"]),
            ("noMatches", ["No matches", "Không có kết quả phù hợp", "一致する項目はありません",
                           "没有匹配的结果", "沒有相符的結果"]),
            ("settingsSections", ["Settings sections", "Mục cài đặt", "設定セクション", "设置分区", "設定分區"]),
            ("people", ["People", "Thành viên", "メンバー", "成员", "成員"]),
            ("workspace", ["Workspace", "Không gian", "ワークスペース", "工作区", "工作區"]),
            ("ai", ["AI", "AI", "AI", "AI", "AI"]),
            ("billing", ["Billing", "Thanh toán", "支払い", "账单", "帳單"]),
            ("hiringPreparing", ["Company hiring is being prepared", "Tính năng thuê cho công ty đang được chuẩn bị",
                                 "会社での採用は準備中です", "公司招聘功能正在准备中", "公司招聘功能正在準備中"]),
            ("companyWallet", ["Company wallet", "Ví công ty", "会社のウォレット", "公司钱包", "公司錢包"]),
            ("openWallet", ["Open", "Mở", "開く", "打开", "開啟"]),
            ("boardViews", ["Board views", "Chế độ xem bảng", "ボードの表示", "看板视图", "看板檢視"]),
            ("suggested", ["Suggested", "Đề xuất", "提案", "建议", "建議"]),
            ("suggestedHint", ["Not on the board until someone accepts it", "Chưa lên bảng cho đến khi có người chấp nhận",
                               "誰かが承認するまでボードには載りません", "有人接受后才会加入看板", "有人接受後才會加入看板"]),
            ("showLessActivity", ["Show less", "Thu gọn", "閉じる", "收起", "收起"]),
            ("preparingChannel", ["Preparing your channel…", "Đang chuẩn bị kênh…", "チャンネルを準備しています…",
                                  "正在准备频道…", "正在準備頻道…"]),
            ("channelFailed", ["Couldn’t open this channel.", "Không mở được kênh này.",
                               "このチャンネルを開けませんでした。", "无法打开此频道。", "無法開啟此頻道。"]),
            ("tryAgain", ["Try again", "Thử lại", "もう一度", "重试", "重試"]),
            ("privateChiefOfStaff", ["Private Chief of Staff", "Chief of Staff riêng", "自分専用の Chief of Staff",
                                     "私人 Chief of Staff", "私人 Chief of Staff"]),
        ]
        XCTAssertEqual(copy.locales, Set(locales))
        for (name, values) in cases {
            let key = prefix + name
            XCTAssertEqual(copy.parameterKinds(key), [], key)
            XCTAssertEqual(values.count, locales.count, key)
            for (locale, value) in zip(locales, values) {
                XCTAssertEqual(try copy.text(key, locale: locale), value, "\(locale): \(key)")
            }
        }
    }

    func testTeamSpaceBoardListAndMineUseDesktopCopyInAllLocales() throws {
        let copy = try AtumCopy()
        let list = "shared.matrix-company-board-copy.copy.list"
        let mine = "shared.matrix-company-board-copy.copy.mine"
        let expected = [
            "en": ("List", "Mine"),
            "vi": ("Danh sách", "Của tôi"),
            "ja": ("リスト", "自分"),
            "zh": ("列表", "我的"),
            "zh-Hant": ("清單", "我的"),
        ]
        XCTAssertEqual(copy.locales, Set(expected.keys))
        XCTAssertEqual(copy.parameterKinds(list), [])
        XCTAssertEqual(copy.parameterKinds(mine), [])
        for (locale, (listLabel, mineLabel)) in expected {
            XCTAssertEqual(try copy.text(list, locale: locale), listLabel, locale)
            XCTAssertEqual(try copy.text(mine, locale: locale), mineLabel, locale)
        }
    }

    func testModelPickerEffortLabelsUseDesktopCopyInAllLocales() throws {
        let copy = try AtumCopy()
        let prefix = "src.matrix.model-picker-copy.COPY.efforts."
        let locales = ["en", "vi", "ja", "zh", "zh-Hant"]
        let cases = [
            ("none", ["Off", "Tắt", "オフ", "关闭", "關閉"]),
            ("minimal", ["Instant", "Tức thì", "即答", "即时", "即時"]),
            ("xhigh", ["Extra thorough", "Rất kỹ", "さらにじっくり", "更深入", "更深入"]),
            ("max", ["Maximum", "Tối đa", "最大", "最大", "最大"]),
        ]
        XCTAssertEqual(copy.locales, Set(locales))
        for (name, values) in cases {
            let key = prefix + name
            XCTAssertEqual(copy.parameterKinds(key), [], key)
            for (locale, value) in zip(locales, values) {
                XCTAssertEqual(try copy.text(key, locale: locale), value, "\(locale): \(key)")
            }
        }
    }

    func testTeamSpaceHeaderSearchInterpolatesTheQueryInAllLocales() throws {
        let copy = try AtumCopy()
        let prefix = "src.matrix.team-space.revamp-copy.copy."
        let query = "Kế hoạch 100%"
        let expected = [
            "en": ("Search “\(query)”", "Search messages for “\(query)”"),
            "vi": ("Tìm “\(query)”", "Tìm tin nhắn có “\(query)”"),
            "ja": ("「\(query)」を検索", "「\(query)」をメッセージから検索"),
            "zh": ("搜索“\(query)”", "在消息中搜索“\(query)”"),
            "zh-Hant": ("搜尋「\(query)」", "在訊息中搜尋「\(query)」"),
        ]
        let search = prefix + "searchFor"
        let messages = prefix + "searchMessagesFor"
        XCTAssertEqual(copy.parameterKinds(search), ["string"])
        XCTAssertEqual(copy.parameterKinds(messages), ["string"])
        for (locale, (searchText, messagesText)) in expected {
            XCTAssertEqual(try copy.text(search, locale: locale, arguments: [.text(query)]), searchText, locale)
            XCTAssertEqual(try copy.text(messages, locale: locale, arguments: [.text(query)]), messagesText, locale)
        }
    }

    func testTeamSpaceBoardActivityPreservesExactCountsAndInterpolation() throws {
        let copy = try AtumCopy()
        let key = "src.matrix.team-space.revamp-copy.copy.showAllActivity"
        XCTAssertEqual(copy.parameterKinds(key), ["number"])
        for count in [0, 1] {
            let branch = key + ".count=\(count)"
            XCTAssertTrue(copy.contains(branch), branch)
            XCTAssertEqual(copy.parameterKinds(branch), ["number"], branch)
        }
        for count: Int64 in [0, 1, 12] {
            let expected = [
                "en": "Show all activity (\(count))",
                "vi": "Xem toàn bộ hoạt động (\(count))",
                "ja": "すべてのアクティビティ (\(count))",
                "zh": "查看全部动态（\(count)）",
                "zh-Hant": "查看全部動態（\(count)）",
            ]
            for (locale, text) in expected {
                XCTAssertEqual(try copy.text(key, locale: locale, arguments: [.number(count)]),
                               text, "\(locale), \(count)")
            }
        }
    }

    func testTypedArgumentsAndMissingLocaleFailInsteadOfEnglishFallback() throws {
        let copy = try AtumCopy()
        XCTAssertThrowsError(try copy.text("desktop.atum.agents.photoUploading", locale: "vi", arguments: [.text("42")]))
        XCTAssertThrowsError(try copy.text("desktop.atum.agents.photoUploading", locale: "vi"))
        XCTAssertThrowsError(try copy.text("desktop.atum.nav.home", locale: "fr"))
        XCTAssertThrowsError(try copy.text("missing.copy", locale: "vi"))
    }
}
