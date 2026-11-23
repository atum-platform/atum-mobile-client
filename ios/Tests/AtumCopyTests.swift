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

    func testTypedArgumentsAndMissingLocaleFailInsteadOfEnglishFallback() throws {
        let copy = try AtumCopy()
        XCTAssertThrowsError(try copy.text("desktop.atum.agents.photoUploading", locale: "vi", arguments: [.text("42")]))
        XCTAssertThrowsError(try copy.text("desktop.atum.agents.photoUploading", locale: "vi"))
        XCTAssertThrowsError(try copy.text("desktop.atum.nav.home", locale: "fr"))
        XCTAssertThrowsError(try copy.text("missing.copy", locale: "vi"))
    }
}
