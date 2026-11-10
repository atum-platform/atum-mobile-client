@testable import AtumMobile
import AtumChat
import AtumDesign
import AtumDrive
import XCTest

final class AccountSettingsStateTests: XCTestCase {
    func testSectionIDsAndOrderStayStableAcrossCapabilityStates() {
        // The desktop's destinations and order (atum-app PR #704).
        let expected = [
            "account", "assistants", "protons",
            "general", "connections", "devices", "privacy",
            "help", "advanced",
        ]
        let unknown = AccountSettingsCapabilities(
            memory: .unknown, pairedDevices: .unknown,
            google: .unknown, advanced: .unknown
        )
        let unavailable = AccountSettingsCapabilities.phone

        XCTAssertEqual(AccountSettingsState(accountID: "@an:atum.invalid",
                                            capabilities: unknown)
            .sections.map(\.rawValue), expected)
        XCTAssertEqual(AccountSettingsState(accountID: "@an:atum.invalid",
                                            capabilities: unavailable)
            .sections.map(\.rawValue), expected)
    }

    func testUnknownCapabilitiesRemainUnknownForTheSameAccount() {
        var state = AccountSettingsState(
            accountID: "@an:atum.invalid",
            capabilities: AccountSettingsCapabilities(memory: .unknown,
                                                       pairedDevices: .unknown,
                                                       google: .unknown,
                                                       advanced: .unknown)
        )
        state.select(.privacy)
        state.reconcile(
            accountID: "@an:atum.invalid",
            capabilities: AccountSettingsCapabilities(memory: .unknown,
                                                       pairedDevices: .unavailable,
                                                       google: .unknown,
                                                       advanced: .unavailable)
        )

        XCTAssertEqual(state.selectedSection, .privacy)
        XCTAssertEqual(state.capabilities.memory, .unknown)
        XCTAssertEqual(state.capabilities.google, .unknown)
    }

    func testAccountChangeDismissesOldDetailAndAdoptsNewCapabilities() {
        var state = AccountSettingsState(accountID: "@an:atum.invalid")
        state.select(.account)
        let replacement = AccountSettingsCapabilities(
            memory: .unknown, pairedDevices: .available,
            google: .unavailable, advanced: .unavailable
        )

        state.reconcile(accountID: "@binh:atum.invalid", capabilities: replacement)

        XCTAssertEqual(state.accountID, "@binh:atum.invalid")
        XCTAssertNil(state.selectedSection)
        XCTAssertEqual(state.capabilities, replacement)
        XCTAssertEqual(state.sections, AccountSettingsSectionID.allCases)
    }

    func testSoleRecoveryKeyStillRequiresSaveBeforeSignOut() {
        XCTAssertEqual(AccountSettingsState.signOutPrompt(
            holdsRecoveryKey: true,
            recoveryKeySavedOnThisPhone: false
        ), .saveRecoveryKey)
        XCTAssertEqual(AccountSettingsState.signOutPrompt(
            holdsRecoveryKey: true,
            recoveryKeySavedOnThisPhone: true
        ), .confirmation)
        XCTAssertEqual(AccountSettingsState.signOutPrompt(
            holdsRecoveryKey: false,
            recoveryKeySavedOnThisPhone: false
        ), .confirmation)
    }

    /// The index draws the desktop's pages in its order, less Advanced (its
    /// tools are desktop-only); the folded destinations still exist as ids.
    func testGroupsDrawTheDesktopPagesInReadingOrder() {
        let state = AccountSettingsState(accountID: "@an:atum.invalid")
        XCTAssertEqual(state.groups.map(\.rawValue), ["you", "app"])
        let pages = state.groups.flatMap(\.sections)
        XCTAssertEqual(pages.map(\.rawValue),
                       ["account", "assistants", "connections", "general", "help"])
        XCTAssertEqual(Set(pages).count, pages.count, "a page appears once")
        XCTAssertTrue(Set(pages).isSubset(of: Set(state.sections)))
        XCTAssertEqual(Set(state.sections).subtracting(pages),
                       [.protons, .devices, .privacy, .advanced])
    }

    /// Every id opens a page the index draws (desktop `settingsPageOf`).
    func testEveryDestinationOpensADrawnPage() {
        let pages = Set(AccountSettingsGroupID.allCases.flatMap(\.sections))
        for section in AccountSettingsSectionID.allCases {
            XCTAssertTrue(pages.contains(section.page), section.rawValue)
        }
        XCTAssertEqual(AccountSettingsSectionID.protons.page, .account)
        XCTAssertEqual(AccountSettingsSectionID.privacy.page, .account)
        XCTAssertEqual(AccountSettingsSectionID.devices.page, .account)
        XCTAssertEqual(AccountSettingsSectionID.advanced.page, .help)
        XCTAssertEqual(AccountSettingsSectionID.connections.page, .connections)
    }

    /// Desktop `AccountPane` + `PrivacyPane`: the recovery key goes last unless
    /// messages must be restored first.
    func testAccountPageFollowsTheDesktopSectionOrder() {
        XCTAssertEqual(AccountPageSection.order(restoresFirst: false),
                       [.howAtumAnswers, .devices, .chats, .memory, .activity, .ignored, .recovery])
        XCTAssertEqual(AccountPageSection.order(restoresFirst: true),
                       [.howAtumAnswers, .recovery, .devices, .chats, .memory, .activity, .ignored])
    }

    /// An available capability no longer reads "Not available" (audit D3).
    func testCapabilityStatusSaysNothingOnceLive() {
        XCTAssertEqual(AccountSettingsCapabilityStatus(.unknown), .loading)
        XCTAssertEqual(AccountSettingsCapabilityStatus(.unavailable), .notAvailableYet)
        XCTAssertEqual(AccountSettingsCapabilityStatus(.available), .live)
    }

    func testEmailSupportDraftsToTheSupportMailbox() throws {
        let url = try XCTUnwrap(AccountSupportMail.url(subject: "Atum support"))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertEqual(url.absoluteString, "mailto:support@atumplatform.com?subject=Atum%20support")
    }

    func testTheBalanceLineCarriesOnlyTheTotal() {
        XCTAssertEqual(AccountSettingsText.protonsLeft.fallback(locale: "en")
            .replacingOccurrences(of: "%1$@", with: "1,240"),
                       "1,240 left · used for Atum’s built-in models and the Store")
        for locale in Self.locales {
            XCTAssertTrue(AccountSettingsText.protonsLeft.fallback(locale: locale).contains("%1$@"), locale)
        }
    }

    /// The pinned export still says "What Atum knows"; the desktop renamed it
    /// "Connections" (`1043f1b48d7`). The stale export must not win.
    func testAStaleExportedTitleDoesNotWin() {
        XCTAssertEqual(AccountSettingsText.destinationConnections.resolved(locale: "en") { _ in
            "What Atum knows"
        }, "Connections")
        XCTAssertEqual(AccountSettingsText.destinationPrivacy.resolved(locale: "en") { _ in
            "exported"
        }, "exported")
    }

    func testApprovedVietnameseAndEnglishSectionFallbacks() {
        XCTAssertEqual(AccountSettingsText.destinationConnections.fallback(locale: "vi"), "Kết nối")
        XCTAssertEqual(AccountSettingsText.destinationConnections.fallback(locale: "en"), "Connections")
        XCTAssertEqual(AccountSettingsText.destinationPrivacy.fallback(locale: "vi"), "Riêng tư & bảo mật")
        XCTAssertEqual(AccountSettingsText.destinationPrivacy.fallback(locale: "en"), "Privacy & security")
        XCTAssertEqual(AccountSettingsText.destinationHelp.fallback(locale: "zh-Hant"), "說明")
        XCTAssertEqual(AccountSettingsText.thisIPhone.fallback(locale: "vi"), "iPhone này")
        XCTAssertEqual(AccountSettingsText.thisIPhone.fallback(locale: "ja"), "この iPhone")
        XCTAssertEqual(AccountSettingsText.shareActivityHelp.fallback(locale: "vi"),
                       "Cho người khác thấy bạn đã xem và đang soạn.")
        XCTAssertEqual(AccountSettingsText.shareActivityHelp.fallback(locale: "en"),
                       "Let others see your read receipts and typing.")
    }

    func testDesktopKeysUseTheDesktopNamespaceAndPhoneKeysTheirOwn() {
        XCTAssertEqual(AccountSettingsText.destinationPrivacy.exportKey,
                       "shared.matrix-settings-revamp-copy.copies.destinations.privacy")
        XCTAssertEqual(AccountSettingsText.thisIPhone.exportKey,
                       "shared.matrix-settings-revamp-copy.phoneSettingsCopy.thisIPhone")
        for key in AccountSettingsText.allCases {
            XCTAssertFalse(key.fallback(locale: "en").isEmpty, key.rawValue)
            XCTAssertFalse(key.fallback(locale: "vi").isEmpty, key.rawValue)
        }
    }

    // MARK: Five locales

    private static let locales = ["en", "vi", "ja", "zh", "zh-Hant"]

    /// The nine destination titles in the five locales: the desktop's own
    /// wording (atum-app `matrix-settings-revamp-copy.ts`), which the plan lists.
    private static let destinationTitles: [String: [AccountSettingsSectionID: String]] = [
        "en": [.account: "Account", .assistants: "Assistants", .protons: "Protons",
               .general: "General", .connections: "Connections", .devices: "This iPhone",
               .privacy: "Privacy & security", .help: "Help", .advanced: "Advanced"],
        "vi": [.account: "Tài khoản", .assistants: "Trợ lý", .protons: "Proton",
               .general: "Chung", .connections: "Kết nối", .devices: "iPhone này",
               .privacy: "Riêng tư & bảo mật", .help: "Trợ giúp", .advanced: "Nâng cao"],
        "ja": [.account: "アカウント", .assistants: "アシスタント", .protons: "Proton",
               .general: "一般", .connections: "接続", .devices: "この iPhone",
               .privacy: "プライバシーと安全", .help: "ヘルプ", .advanced: "詳細"],
        "zh": [.account: "账户", .assistants: "助手", .protons: "Proton",
               .general: "通用", .connections: "连接", .devices: "这台 iPhone",
               .privacy: "隐私与安全", .help: "帮助", .advanced: "高级"],
        "zh-Hant": [.account: "帳戶", .assistants: "助理", .protons: "Proton",
                    .general: "一般", .connections: "連接", .devices: "這台 iPhone",
                    .privacy: "隱私與安全", .help: "說明", .advanced: "進階"],
    ]

    /// What Settings shows for a destination in a locale: the export's text for
    /// the words it carries, the export's text or the phone's fallback for the
    /// words it owes. Exactly the path `AccountSettingsCopy.sectionTitle` takes.
    private func title(_ section: AccountSettingsSectionID, locale: String,
                       copy: AtumCopy, isPad: Bool = false) throws -> String {
        switch section.title(isPad: isPad) {
        case let .exported(key):
            return try copy.text(key, locale: locale)
        case let .owed(text):
            return text.resolved(locale: locale) { key in
                copy.contains(key) ? try? copy.text(key, locale: locale) : nil
            }
        }
    }

    func testNineDestinationTitlesReadTheDesktopsWordsInAllFiveLocales() throws {
        let copy = try AtumCopy()
        XCTAssertEqual(Set(Self.locales), copy.locales, "the export gained or lost a locale")
        for locale in Self.locales {
            let expected = try XCTUnwrap(Self.destinationTitles[locale])
            XCTAssertEqual(Set(expected.keys), Set(AccountSettingsSectionID.allCases))
            for section in AccountSettingsSectionID.allCases {
                XCTAssertEqual(try title(section, locale: locale, copy: copy), expected[section],
                               "\(section.rawValue) in \(locale)")
            }
        }
    }

    func testThisIPadReadsLikeThisIPhoneInEveryLocale() throws {
        let copy = try AtumCopy()
        let expected = ["en": "This iPad", "vi": "iPad này", "ja": "この iPad",
                        "zh": "这台 iPad", "zh-Hant": "這台 iPad"]
        for locale in Self.locales {
            XCTAssertEqual(try title(.devices, locale: locale, copy: copy, isPad: true), expected[locale], locale)
        }
    }

    func testSignOutDialogKeepsThePinnedDesktopWords() throws {
        let copy = try AtumCopy()
        XCTAssertEqual(try copy.text("src.matrix.mobile-copy.mobilePhoneCopy.signOutTitle", locale: "vi"),
                       "Đăng xuất khỏi iPhone này?")
        XCTAssertEqual(try copy.text("src.matrix.mobile-copy.mobilePhoneCopy.signOutBody", locale: "vi"),
                       "Các cuộc trò chuyện vẫn nằm trong tài khoản của bạn.")
    }

    func testAKeyTheExportCarriesWinsOverThePhonesFallback() {
        let text = AccountSettingsText.thisIPhone
        XCTAssertEqual(text.resolved(locale: "ja") { key in
            key == "shared.matrix-settings-revamp-copy.phoneSettingsCopy.thisIPhone" ? "exported" : nil
        }, "exported")
        XCTAssertEqual(text.resolved(locale: "ja") { _ in nil }, "この iPhone")
    }

    func testEveryFallbackReadsInAllFiveLocales() {
        // Seventeen of these used to read English in ja, zh and zh-Hant (audit D8).
        let brands: Set<AccountSettingsText> = [.groupApp, .google]
        for key in AccountSettingsText.allCases {
            let english = key.fallback(locale: "en")
            for locale in Self.locales {
                XCTAssertFalse(key.fallback(locale: locale).isEmpty, "\(key.rawValue) \(locale)")
            }
            for locale in ["ja", "zh", "zh-Hant"] where !brands.contains(key) {
                XCTAssertNotEqual(key.fallback(locale: locale), english,
                                  "\(key.rawValue) still reads English in \(locale)")
            }
        }
        XCTAssertEqual(AccountSettingsText.nameRequired.fallback(locale: "zh-Hant"), "請輸入名字。")
        XCTAssertEqual(AccountSettingsText.assistantPrepared.fallback(locale: "ja"), "アシスタントを準備しています")
    }

    func testReportingSwitchesReadInAllFiveLocales() {
        let keys: [AccountSettingsText] = [
            .shareCrashReports, .shareCrashReportsHelp,
            .shareUsageData, .shareUsageDataHelp, .reportingFooter,
        ]
        for key in keys {
            let values = Self.locales.map { key.fallback(locale: $0) }
            XCTAssertEqual(Set(values).count, Self.locales.count, key.rawValue)
            XCTAssertFalse(values.contains(where: \.isEmpty), key.rawValue)
        }
        XCTAssertEqual(AccountSettingsText.shareCrashReports.fallback(locale: "vi"),
                       "Chia sẻ báo cáo sự cố")
        XCTAssertEqual(AccountSettingsText.shareCrashReports.fallback(locale: "en"),
                       "Share crash reports")
        XCTAssertEqual(AccountSettingsText.shareUsageData.fallback(locale: "vi"),
                       "Chia sẻ dữ liệu sử dụng")
        XCTAssertEqual(AccountSettingsText.shareUsageData.fallback(locale: "en"),
                       "Share usage data")
    }

    func testLocaleSpellingsFindTheirTable() {
        XCTAssertEqual(AccountSettingsText.destinationHelp.fallback(locale: "zh_Hant_TW"), "說明")
        XCTAssertEqual(AccountSettingsText.destinationHelp.fallback(locale: "zh-Hans"), "帮助")
        XCTAssertEqual(AccountSettingsText.destinationHelp.fallback(locale: "ja_JP"), "ヘルプ")
        XCTAssertEqual(AccountSettingsText.destinationHelp.fallback(locale: "fr"), "Help")
    }

    func testTheGroupsAreNamedForAssistiveTechnologyInEveryLocale() {
        let state = AccountSettingsState(accountID: "@an:atum.invalid")
        XCTAssertEqual(state.groups.map(\.accessibilityName), [.groupYou, .groupApp])
        XCTAssertEqual(AccountSettingsText.groupYou.fallback(locale: "vi"), "Bạn")
        XCTAssertEqual(AccountSettingsText.groupApp.exportKey,
                       "shared.matrix-settings-revamp-copy.copies.groups.app")
    }

    func testEveryExportKeyThePagesReadExistsInAllFiveLocales() throws {
        // `LiveDesign.text` stops the app on a missing key, so a key the new
        // code reads must be in the export in every locale.
        let copy = try AtumCopy()
        let keys = [
            "desktop.atum.settings.title",
            "src.matrix.copy.copies.ready", "src.matrix.copy.copies.connecting",
            "src.matrix.copy.copies.offline",
            "src.matrix.copy.copies.enrollmentAbsent",
            "src.matrix.profile-copy.copies.displayName",
            "src.matrix.profile-copy.copies.displayNameHint",
            "src.matrix.profile-copy.copies.nameFailed",
            "desktop.atum.account.changePhoto", "desktop.atum.account.removePhoto",
            "desktop.atum.account.photoUploading", "desktop.atum.account.photoTooLarge",
            "desktop.atum.account.photoFailed",
            "src.matrix.assistant-card.copy.assistantCardCopies.photoError",
            // AC-3 pages.
            "desktop.atum.protons.title", "desktop.common.loading",
            "desktop.atum.settings.textSize", "desktop.atum.settings.about",
            "src.matrix.settings-copy.copy.display", "src.matrix.settings-copy.copy.notifications",
            "src.matrix.settings-copy.copy.improve", "src.matrix.settings-copy.copy.encryptedMessages",
            "src.matrix.model-picker-copy.COPY.subscriptions",
            "src.matrix.security-copy.copies.devicesTitle",
            "src.matrix.moderation-copy.copies.ignoredPeople",
            "src.matrix.moderation-copy.copies.ignoredHow",
            "src.matrix.founder.founder-copy.FOUNDER_COPY.contactTitle",
            "src.matrix.founder.founder-copy.FOUNDER_COPY.name",
            "src.matrix.founder.founder-copy.FOUNDER_COPY.emailSupport",
            "src.matrix.founder.founder-copy.FOUNDER_COPY.emailSubject",
            "src.matrix.legal-copy.copy.legal",
            "src.matrix.mobile-device-copy.mobileDeviceCopy.uiStore",
            // AC-4 Drive.
            "src.matrix.drive-copy.matrixDriveCopy.emptyRoot.title",
            "src.matrix.drive-copy.matrixDriveCopy.comingSoonHelp",
            "src.matrix.drive-copy.matrixDriveCopy.status.ready",
            "src.matrix.drive-copy.matrixDriveCopy.empty",
        ]
        for locale in Self.locales {
            for key in keys {
                XCTAssertFalse(try copy.text(key, locale: locale).isEmpty, "\(key) in \(locale)")
            }
        }
    }

    @MainActor
    func testDrivePlacesReadTheDesktopsWordsInAllFiveLocales() {
        for locale in Self.locales {
            let normalized = AccountSettingsText.normalizedLocale(locale)
            XCTAssertNotNil(DriveCopy.recentsFallback[normalized], locale)
            XCTAssertNotNil(DriveCopy.allFilesFallback[normalized], locale)
        }
        XCTAssertEqual(DriveCopy.recentsFallback["vi"], "Gần đây")
        XCTAssertEqual(DriveCopy.allFilesFallback["zh-hant"], "所有檔案")
    }

    func testEveryDriveFamilyHasAPhosphorGlyph() {
        for family in DriveFileFamily.allCases {
            XCTAssertNotNil(PhosphorSymbols.aliases[family.glyphAlias], family.rawValue)
        }
    }
}
