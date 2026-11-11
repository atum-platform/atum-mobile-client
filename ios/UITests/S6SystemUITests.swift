import AtumChat
import XCTest

/// S6's scripted simulator acceptance matrix. Every host is synthetic: these
/// tests never sign in, mutate a real account, or depend on live product data.
final class S6SystemUITests: TranscriptUITestCase {
    private static let defaultSize = "UICTContentSizeCategoryL"
    private static let ax5Size = "UICTContentSizeCategoryAccessibilityXXXL"

    @MainActor
    func testU1AndU2VisualFoundationAndWelcome() {
        let gallery = launchS6("system.gallery")
        XCTAssertTrue(element(gallery, "system.gallery").waitForExistence(timeout: 15))
        assertS6TextSafe(gallery)
        keepScreenshot("U-S6-1-system-gallery-light-vi", of: gallery)
        for _ in 0..<3 { gallery.scrollViews.firstMatch.swipeUp() }
        keepScreenshot("U-S6-1-system-gallery-light-vi-bottom", of: gallery)
        gallery.terminate()

        let welcome = launchS6("welcome")
        XCTAssertTrue(element(welcome, "welcome.screen").waitForExistence(timeout: 15))
        XCTAssertTrue(welcome.staticTexts["Trợ lý của bạn, ở mọi nơi."].exists)
        XCTAssertTrue(welcome.buttons["Tiếp tục"].exists)
        XCTAssertTrue(welcome.links["Điều khoản"].exists)
        XCTAssertTrue(welcome.links["Chính sách quyền riêng tư"].exists)
        assertS6TextSafe(welcome)
        assertNoSystemBlue(welcome)
        keepScreenshot("U-S6-2-welcome-light-vi", of: welcome)
    }

    @MainActor
    func testU1AndU2DarkAndAX5Evidence() {
        useDarkAppearance()
        defer { useLightAppearance() }

        let darkGallery = launchS6("system.gallery")
        XCTAssertTrue(element(darkGallery, "system.gallery").waitForExistence(timeout: 15))
        assertDark(darkGallery, screen: "gallery")
        keepScreenshot("U-S6-1-system-gallery-dark-vi", of: darkGallery)
        for _ in 0..<3 { darkGallery.scrollViews.firstMatch.swipeUp() }
        keepScreenshot("U-S6-1-system-gallery-dark-vi-bottom", of: darkGallery)
        darkGallery.terminate()

        let darkWelcome = launchS6("welcome")
        XCTAssertTrue(element(darkWelcome, "welcome.screen").waitForExistence(timeout: 15))
        assertDark(darkWelcome, screen: "welcome")
        assertNoSystemBlue(darkWelcome)
        keepScreenshot("U-S6-2-welcome-dark-vi", of: darkWelcome)
        darkWelcome.terminate()

        useLightAppearance()
        let axWelcome = launchS6("welcome", contentSize: Self.ax5Size)
        XCTAssertTrue(element(axWelcome, "welcome.screen").waitForExistence(timeout: 15))
        XCTAssertTrue(axWelcome.buttons["Tiếp tục"].isHittable)
        keepScreenshot("U-S6-2-welcome-light-ax5-vi", of: axWelcome)
    }

    @MainActor
    func testU3AndU4WelcomeStates() {
        let cancelled = launchS6("welcome.cancelled")
        XCTAssertTrue(cancelled.staticTexts["Đã hủy đăng nhập. Bạn có thể thử lại."].waitForExistence(timeout: 15))
        keepScreenshot("U-S6-3-welcome-cancelled-light-vi", of: cancelled)
        cancelled.terminate()

        let expired = launchS6("welcome.expired")
        XCTAssertTrue(expired.staticTexts["Đăng nhập lại để tiếp tục"].waitForExistence(timeout: 15))
        XCTAssertTrue(expired.staticTexts["Phiên đăng nhập đã hết hạn. Cuộc trò chuyện của bạn vẫn được giữ nguyên."].exists)
        keepScreenshot("U-S6-3-welcome-expired-light-vi", of: expired)
        expired.terminate()

        let busy = launchS6("welcome.busy", disablesAnimations: false)
        let busyButton = element(busy, "live-sign-in")
        XCTAssertTrue(busyButton.waitForExistence(timeout: 15))
        XCTAssertEqual(busyButton.label, "Đang đăng nhập")
        let spokenBusy = busy.staticTexts["Đang đăng nhập"]
        if spokenBusy.exists {
            XCTAssertEqual(spokenBusy.frame, busyButton.frame,
                           "busy copy must be the button's accessibility label, not separately drawn words")
        }
        if busyButton.elementType == .button { XCTAssertFalse(busyButton.isEnabled) }
        keepScreenshot("U-S6-4-welcome-busy-light-vi", of: busy)
        busy.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let darkBusy = launchS6("welcome.busy", disablesAnimations: false)
        XCTAssertTrue(element(darkBusy, "live-sign-in").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-4-welcome-busy-dark-vi", of: darkBusy)
    }

    @MainActor
    func testU5StatusScreensAndQuietEscape() {
        let cannotConnect = launchS6("status.cant-connect")
        XCTAssertTrue(element(cannotConnect, "status.screen").waitForExistence(timeout: 15))
        XCTAssertTrue(cannotConnect.staticTexts["Atum chưa kết nối được. Kiểm tra kết nối rồi thử lại."].exists)
        XCTAssertTrue(cannotConnect.buttons["Thử lại"].exists)
        XCTAssertTrue(cannotConnect.buttons["Đăng xuất"].exists)
        keepScreenshot("U-S6-5-status-cant-connect-light-vi", of: cannotConnect)
        cannotConnect.buttons["Đăng xuất"].tap()
        XCTAssertTrue(element(cannotConnect, "welcome.screen").waitForExistence(timeout: 3))
        cannotConnect.terminate()

        let domain = launchS6("status.domain")
        XCTAssertTrue(element(domain, "status.screen").waitForExistence(timeout: 15))
        XCTAssertTrue(domain.buttons["Tiếp tục"].exists)
        XCTAssertFalse(domain.buttons["Đăng xuất"].exists)
        keepScreenshot("U-S6-5-status-domain-light-vi", of: domain)
        domain.terminate()

        let ax = launchS6("status.cant-connect", contentSize: Self.ax5Size)
        XCTAssertTrue(element(ax, "status.screen").waitForExistence(timeout: 15))
        XCTAssertTrue(ax.buttons["Đăng xuất"].isHittable)
        keepScreenshot("U-S6-5-status-cant-connect-light-ax5-vi", of: ax)
        ax.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let dark = launchS6("status.cant-connect")
        XCTAssertTrue(element(dark, "status.screen").waitForExistence(timeout: 15))
        assertDark(dark, screen: "status")
        keepScreenshot("U-S6-5-status-cant-connect-dark-vi", of: dark)
    }

    @MainActor
    func testU6BootWaitDelaysItsOnlyAccessibilityLabel() {
        let zero = Date().addingTimeInterval(60)
        let app = launchS6("boot.slow", disablesAnimations: false,
                           extra: ["-AtumScriptedStartAt", String(zero.timeIntervalSince1970)])
        let opening = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Đang mở Atum")).firstMatch
        XCTAssertLessThan(Date(), zero, "the scripted clock started before launch completed")
        wait(until: zero.addingTimeInterval(0.45))
        XCTAssertFalse(opening.exists, "the boot mark appeared before its one-second delay")
        wait(until: zero.addingTimeInterval(1.5))
        XCTAssertTrue(opening.waitForExistence(timeout: 3))
        let labels = visibleTexts(app).filter { !$0.isEmpty && $0 != app.label }
        XCTAssertTrue(labels.allSatisfy { $0 == "Đang mở Atum" }, "unexpected boot text: \(labels)")
        keepScreenshot("U-S6-6-boot-slow-light-vi", of: app)
        app.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let dark = launchS6("boot.slow", disablesAnimations: false)
        XCTAssertTrue(dark.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Đang mở Atum"))
            .firstMatch.waitForExistence(timeout: 3))
        keepScreenshot("U-S6-6-boot-slow-dark-vi", of: dark)
    }

    @MainActor
    func testU7StoreCatalogAndVariants() {
        let app = launchS6("store.catalog")
        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "store.balance").exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Mở")).count, 1)
        keepScreenshot("U-S6-7-store-catalog-light-vi", of: app)
        for section in ["Nổi bật", "Ứng dụng", "Trợ lý"] {
            XCTAssertTrue(scrollTo(labelled(app, section), in: app), "missing Store section \(section)")
        }
        XCTAssertTrue(scrollTo(app.staticTexts["Miễn phí"], in: app))
        for section in ["Kỹ năng", "Thú cưng"] {
            XCTAssertTrue(scrollTo(labelled(app, section), in: app), "missing Store section \(section)")
        }
        assertNoStorePurchaseWords(app)
        assertS6TextSafe(app)
        keepScreenshot("U-S6-7-store-catalog-light-vi-bottom", of: app)
        app.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let dark = launchS6("store.catalog")
        XCTAssertTrue(element(dark, "store.catalog").waitForExistence(timeout: 15))
        assertDark(dark, screen: "store")
        keepScreenshot("U-S6-7-store-catalog-dark-vi", of: dark)
        for _ in 0..<3 { dark.collectionViews.firstMatch.swipeUp() }
        keepScreenshot("U-S6-7-store-catalog-dark-vi-bottom", of: dark)
        dark.terminate()

        useLightAppearance()
        let ax = launchS6("store.catalog", contentSize: Self.ax5Size)
        XCTAssertTrue(element(ax, "store.catalog").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-7-store-catalog-light-ax5-vi", of: ax)
        // The free item's row is one button whose label ends with its price.
        XCTAssertTrue(scrollTo(element(ax, "store.item.assistant"), in: ax))
        XCTAssertTrue(element(ax, "store.item.assistant").label.hasSuffix("Miễn phí"))
        keepScreenshot("U-S6-7-store-catalog-light-ax5-vi-bottom", of: ax)
    }

    @MainActor
    func testU8EveryStoreState() {
        let zero = Date().addingTimeInterval(60)
        let loading = launchS6("store.first-load", disablesAnimations: false,
                                extra: ["-AtumScriptedStartAt", String(zero.timeIntervalSince1970)])
        let loadingMark = element(loading, "store.loading")
        XCTAssertLessThan(Date(), zero, "the scripted clock started before launch completed")
        wait(until: zero.addingTimeInterval(0.2))
        XCTAssertFalse(loadingMark.exists, "first-load atom appeared before 400 ms")
        wait(until: zero.addingTimeInterval(0.65))
        XCTAssertTrue(loadingMark.waitForExistence(timeout: 3))
        keepScreenshot("U-S6-8-store-first-load-light-vi", of: loading)
        loading.terminate()

        let empty = launchS6("store.empty")
        XCTAssertTrue(empty.staticTexts["Chưa có gì ở đây."].waitForExistence(timeout: 15))
        keepScreenshot("U-S6-8-store-empty-light-vi", of: empty)
        empty.terminate()

        let unavailable = launchS6("store.unavailable")
        XCTAssertTrue(element(unavailable, "store.unavailable").waitForExistence(timeout: 15))
        XCTAssertTrue(unavailable.buttons["Thử lại"].exists)
        keepScreenshot("U-S6-8-store-unavailable-light-vi", of: unavailable)
        unavailable.terminate()

        let stale = launchS6("store.stale")
        XCTAssertTrue(element(stale, "store.catalog").waitForExistence(timeout: 15))
        XCTAssertTrue(scrollTo(stale.staticTexts["Đang hiển thị danh mục đã lưu trong khi kết nối lại."], in: stale))
        keepScreenshot("U-S6-8-store-stale-light-vi", of: stale)
        stale.terminate()

        let partial = launchS6("store.partial")
        XCTAssertTrue(element(partial, "store.catalog").waitForExistence(timeout: 15))
        // Desktop `discover-view.tsx` drops the header balance when the wallet
        // has not loaded; "Chưa có số dư" belongs to the retired legacy wallet.
        XCTAssertFalse(element(partial, "store.balance").exists)
        XCTAssertFalse(partial.buttons["Mở"].exists)
        keepScreenshot("U-S6-8-store-partial-light-vi", of: partial)
        partial.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let darkLoading = launchS6("store.first-load", disablesAnimations: false)
        XCTAssertTrue(element(darkLoading, "store.loading").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-8-store-first-load-dark-vi", of: darkLoading)
    }

    @MainActor
    func testU9StoreOpenPushesItsScriptedRoom() {
        let app = launchS6("store.open-app")
        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 15))
        // The app row is the button (design review S1), labelled with its action.
        let open = element(app, "store.open.moon")
        XCTAssertTrue(scrollTo(open, in: app))
        XCTAssertTrue(open.label.hasSuffix("Mở"))
        open.tap()
        XCTAssertTrue(element(app, "scripted.moon-chat").waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 3))
        keepScreenshot("U-S6-9-store-open-app-light-vi", of: app)
    }

    @MainActor
    func testU10AccountDefaultAndVariants() {
        let account = launchS6("account.default")
        XCTAssertTrue(element(account, "account.screen").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-10-account-default-light-vi-top", of: account)
        assertAccountDefault(account)
        keepScreenshot("U-S6-10-account-default-light-vi", of: account)
        account.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let dark = launchS6("account.default")
        XCTAssertTrue(element(dark, "account.screen").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-10-account-default-dark-vi-top", of: dark)
        assertAccountDefault(dark)
        assertDark(dark, screen: "account")
        keepScreenshot("U-S6-10-account-default-dark-vi", of: dark)
        dark.terminate()

        useLightAppearance()
        let ax = launchS6("account.default", contentSize: Self.ax5Size)
        XCTAssertTrue(element(ax, "account.screen").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-10-account-default-light-ax5-vi-top", of: ax)
        assertAccountDefault(ax)
        keepScreenshot("U-S6-10-account-default-light-ax5-vi", of: ax)
    }

    @MainActor
    func testU11RestoreMessagesRejectedAndDone() {
        let restore = launchS6("account.restore")
        XCTAssertTrue(element(restore, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("privacy", in: restore)
        let restoreRow = restore.buttons["Khôi phục tin nhắn"].firstMatch
        XCTAssertTrue(restoreRow.waitForExistence(timeout: 3))
        restoreRow.tap()
        XCTAssertTrue(element(restore, "account.restore.sheet").waitForExistence(timeout: 3))
        keepScreenshot("U-S6-11-account-restore-sheet-light-vi", of: restore)
        restore.terminate()

        let rejected = launchS6("recovery.rejected")
        XCTAssertTrue(element(rejected, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("privacy", in: rejected)
        XCTAssertTrue(rejected.buttons["Khôi phục tin nhắn"].firstMatch.waitForExistence(timeout: 3))
        rejected.buttons["Khôi phục tin nhắn"].firstMatch.tap()
        let rejectedField = element(rejected, "account.restore.field")
        XCTAssertTrue(rejectedField.waitForExistence(timeout: 3))
        rejectedField.tap()
        rejectedField.typeText("WRONG KEY")
        element(rejected, "account.restore.submit").tap()
        XCTAssertTrue(rejected.staticTexts["Không thể khôi phục khóa này. Hãy thử lại."].waitForExistence(timeout: 3))
        XCTAssertFalse((rejectedField.value as? String ?? "").isEmpty, "a rejected key was cleared")
        keepScreenshot("U-S6-11-recovery-rejected-light-vi", of: rejected)
        rejected.terminate()

        let done = launchS6("recovery.done")
        XCTAssertTrue(element(done, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("privacy", in: done)
        XCTAssertTrue(done.buttons["Khôi phục tin nhắn"].firstMatch.waitForExistence(timeout: 3))
        done.buttons["Khôi phục tin nhắn"].firstMatch.tap()
        let doneField = element(done, "account.restore.field")
        XCTAssertTrue(doneField.waitForExistence(timeout: 3))
        doneField.tap()
        doneField.typeText("SAVED KEY")
        element(done, "account.restore.submit").tap()
        XCTAssertTrue(element(done, "account.restore.done").waitForExistence(timeout: 3))
        XCTAssertTrue(done.staticTexts["Đã mở lại tin nhắn cũ."].exists)
        keepScreenshot("U-S6-11-recovery-done-light-vi", of: done)
        done.buttons["Xong"].tap()
        XCTAssertFalse(done.buttons["Khôi phục tin nhắn"].firstMatch.waitForExistence(timeout: 1))
    }

    @MainActor
    func testU11RestoreAccessibility() throws {
        let app = launchS6("account.restore")
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("privacy", in: app)
        XCTAssertTrue(app.buttons["Khôi phục tin nhắn"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["Khôi phục tin nhắn"].firstMatch.tap()
        XCTAssertTrue(element(app, "account.restore.sheet").waitForExistence(timeout: 3))
        try auditIgnoringScrollEdges(app)
    }

    @MainActor
    func testU11RestoreDarkAndAX5Evidence() {
        useDarkAppearance()
        defer { useLightAppearance() }
        let dark = launchS6("account.restore")
        XCTAssertTrue(element(dark, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("privacy", in: dark)
        XCTAssertTrue(dark.buttons["Khôi phục tin nhắn"].firstMatch.waitForExistence(timeout: 3))
        dark.buttons["Khôi phục tin nhắn"].firstMatch.tap()
        XCTAssertTrue(element(dark, "account.restore.sheet").waitForExistence(timeout: 3))
        keepScreenshot("U-S6-11-account-restore-sheet-dark-vi", of: dark)
        dark.terminate()

        useLightAppearance()
        let ax = launchS6("account.restore", contentSize: Self.ax5Size)
        XCTAssertTrue(element(ax, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("privacy", in: ax)
        XCTAssertTrue(ax.buttons["Khôi phục tin nhắn"].firstMatch.waitForExistence(timeout: 3))
        ax.buttons["Khôi phục tin nhắn"].firstMatch.tap()
        XCTAssertTrue(element(ax, "account.restore.sheet").waitForExistence(timeout: 3))
        keepScreenshot("U-S6-11-account-restore-sheet-light-ax5-vi", of: ax)
    }

    @MainActor
    func testU12RecoveryKeyCopyAndDarkEvidence() {
        let key = launchS6("account.key")
        openRecoveryKey(in: key)
        XCTAssertTrue(key.buttons["Sao chép"].exists)
        key.buttons["Sao chép"].tap()
        XCTAssertTrue(key.buttons["Đã sao chép"].waitForExistence(timeout: 2))
        keepScreenshot("U-S6-12-account-key-copied-light-vi", of: key)
        captureRecoveryKeyAppSwitcher(in: key)
        key.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let dark = launchS6("account.key")
        openRecoveryKey(in: dark)
        keepScreenshot("U-S6-12-account-key-dark-vi", of: dark)
    }

    @MainActor
    func testU13PlainSignOutCancelAndConfirm() {
        let app = launchS6("signout.plain")
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("account", in: app)
        let signOut = app.buttons.matching(identifier: "account.sign-out").firstMatch
        XCTAssertTrue(scrollSettingsList(to: signOut, in: app))
        signOut.press(forDuration: 0.1)
        let title = app.staticTexts["Đăng xuất khỏi iPhone này?"].firstMatch
        guard title.waitForExistence(timeout: 10) else {
            return XCTFail("sign-out dialog did not appear: \(boundedHierarchy(app, limit: 30_000))")
        }
        let alert = app.alerts["Đăng xuất khỏi iPhone này?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let confirm = alert.buttons["Đăng xuất"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let cancel = alert.buttons["Hủy"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Các cuộc trò chuyện vẫn nằm trong tài khoản của bạn.")
        ).firstMatch.exists)
        keepScreenshot("U-S6-13-signout-dialog-light-vi", of: app)
        cancel.tap()
        XCTAssertTrue(element(app, "account.settings.account").waitForExistence(timeout: 2))
        let secondSignOut = app.buttons.matching(identifier: "account.sign-out").firstMatch
        XCTAssertTrue(scrollSettingsList(to: secondSignOut, in: app))
        secondSignOut.press(forDuration: 0.1)
        guard title.waitForExistence(timeout: 10) else {
            return XCTFail("second sign-out dialog did not appear: \(boundedHierarchy(app, limit: 30_000))")
        }
        let secondAlert = app.alerts["Đăng xuất khỏi iPhone này?"].firstMatch
        XCTAssertTrue(secondAlert.waitForExistence(timeout: 3))
        secondAlert.buttons["Đăng xuất"].tap()
        XCTAssertTrue(element(app, "welcome.screen").waitForExistence(timeout: 10))
    }

    @MainActor
    func testU14SaveKeySignOutCancelAndConfirm() {
        let app = launchS6("signout.save-key")
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("account", in: app)
        XCTAssertTrue(scrollSettingsList(to: element(app, "account.sign-out"), in: app))
        element(app, "account.sign-out").tap()
        XCTAssertTrue(element(app, "account.recovery.key-sheet").waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Đăng xuất khỏi iPhone này?"].exists)
        keepScreenshot("U-S6-14-signout-save-key-light-vi", of: app)
        app.buttons["Đóng"].tap()
        XCTAssertTrue(element(app, "account.sign-out").waitForExistence(timeout: 2),
                      "closing the key sheet left the Account page")
        element(app, "account.sign-out").tap()
        XCTAssertTrue(app.buttons["Tôi đã lưu khóa; đăng xuất"].waitForExistence(timeout: 3))
        app.buttons["Tôi đã lưu khóa; đăng xuất"].tap()
        XCTAssertTrue(element(app, "welcome.screen").waitForExistence(timeout: 3))
        app.terminate()

        useDarkAppearance()
        defer { useLightAppearance() }
        let dark = launchS6("signout.save-key")
        XCTAssertTrue(element(dark, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("account", in: dark)
        XCTAssertTrue(scrollSettingsList(to: element(dark, "account.sign-out"), in: dark))
        element(dark, "account.sign-out").tap()
        XCTAssertTrue(element(dark, "account.recovery.key-sheet").waitForExistence(timeout: 3))
        keepScreenshot("U-S6-14-signout-save-key-dark-vi", of: dark)
    }

    @MainActor
    func testU15LegalLicencesAndInAppSafari() {
        let app = launchS6("account.legal")
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("help", in: app)
        app.buttons["Pháp lý"].tap()
        XCTAssertTrue(element(app, "account.legal.screen").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "account.legal.terms").exists)
        XCTAssertTrue(element(app, "account.legal.privacy").exists)
        keepScreenshot("U-S6-15-account-legal-light-vi", of: app)

        element(app, "account.legal.licences-link").tap()
        XCTAssertTrue(element(app, "account.licences.screen").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Atum Mobile")).firstMatch.exists)
        keepScreenshot("U-S6-15-account-licences-light-vi", of: app)
        app.navigationBars.buttons.firstMatch.tap()

        element(app, "account.legal.terms").tap()
        let close = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Đóng", "Close", "Xong", "Done"]
        )).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Terms did not open in SFSafariViewController")
        XCTAssertEqual(app.state, .runningForeground, "Terms left Atum")
        close.tap()
    }

    /// RT is opt-in because it needs `scripts/sim-content-size-runner.sh`
    /// beside xcodebuild. The evidence run sets `TEST_RUNNER_ATUM_S6_RT=1`.
    @MainActor
    func testU1U7U10ReduceTransparencyAndContrastEvidence() throws {
        guard ProcessInfo.processInfo.environment["ATUM_S6_RT"] == "1" else {
            throw XCTSkip("set ATUM_S6_RT=1 with the simulator settings runner")
        }
        guard requestRunner("transparency on"), requestRunner("contrast on") else {
            throw XCTSkip("no simulator settings runner beside this test")
        }
        defer {
            requestRunner("contrast off")
            requestRunner("transparency off")
        }

        let gallery = launchS6("system.gallery")
        XCTAssertTrue(element(gallery, "system.gallery").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-1-system-gallery-light-rt-vi", of: gallery)
        gallery.terminate()

        let store = launchS6("store.catalog")
        XCTAssertTrue(element(store, "store.catalog").waitForExistence(timeout: 15))
        keepScreenshot("U-S6-7-store-catalog-light-rt-vi", of: store)
        store.terminate()

        let account = launchS6("account.default")
        assertAccountDefault(account)
        keepScreenshot("U-S6-10-account-default-light-rt-vi", of: account)
    }

    /// U-S6-16: one accessibility and visible-text pass for every distinct
    /// initial screen. Modal states receive their own audits in the flow tests.
    @MainActor
    func testU16AccessibilityAndVisibleTextMatrix() throws {
        let cells: [(String, String, TimeInterval)] = [
            ("system.gallery", "system.gallery", 0),
            ("welcome", "welcome.screen", 0),
            ("welcome.cancelled", "welcome.screen", 0),
            ("welcome.expired", "welcome.screen", 0),
            ("welcome.busy", "welcome.screen", 0),
            ("status.cant-connect", "status.screen", 0),
            ("status.domain", "status.screen", 0),
            ("boot.slow", "boot.wait", 1.3),
            ("store.catalog", "store.catalog", 0),
            ("store.first-load", "store.loading", 0.6),
            ("store.empty", "store.catalog", 0),
            ("store.unavailable", "store.unavailable", 0),
            ("store.stale", "store.catalog", 0),
            ("store.partial", "store.catalog", 0),
            ("store.open-app", "store.catalog", 0),
            ("account.default", "account.screen", 0),
            ("account.restore", "account.screen", 0),
            ("recovery.rejected", "account.screen", 0),
            ("recovery.done", "account.screen", 0),
            ("account.key", "account.screen", 0),
            ("signout.plain", "account.screen", 0),
            ("signout.save-key", "account.screen", 0),
            ("account.legal", "account.screen", 0),
        ]
        let start = ProcessInfo.processInfo.environment["ATUM_S6_AUDIT_START"]
        let selected: ArraySlice<(String, String, TimeInterval)>
        if let start, let index = cells.firstIndex(where: { $0.0 == start }) {
            selected = cells[index...]
        } else {
            selected = cells[...]
        }
        for (scenario, identifier, delay) in selected {
            print("S6AUDIT scenario=\(scenario)")
            let app = launchS6(scenario, disablesAnimations: scenario != "boot.slow")
            if delay > 0 { wait(delay) }
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 15), scenario)
            assertS6TextSafe(app)
            try auditIgnoringScrollEdges(app)
            app.terminate()
        }
    }

    /// Wave 3 AC-8: Your devices lists the account's other sessions by name and
    /// last activity (never an ID); signing one out asks here, then opens the
    /// sign-in server's own confirmation page; recovery says "Not set up".
    @MainActor
    func testU17YourDevicesSignOutAndRecoveryStatus() {
        let app = launchS6("account.devices")
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("devices", in: app)
        let mac = element(app, "account.settings.privacy.devices.other.0")
        XCTAssertTrue(mac.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollSettingsList(to: mac, in: app))
        XCTAssertEqual(mac.label, "MacBook Pro")
        XCTAssertTrue((mac.value as? String)?.hasPrefix("Hoạt động") == true, "no last-active line")
        let unnamed = element(app, "account.settings.privacy.devices.other.1")
        XCTAssertTrue(scrollSettingsList(to: unnamed, in: app))
        XCTAssertEqual(unnamed.label, "Thiết bị khác")
        XCTAssertFalse(visibleTexts(app).contains { $0.contains("SCRIPTED") }, "a device ID is visible")
        assertS6TextSafe(app)
        keepScreenshot("U-S6-17-devices-light-vi", of: app)

        XCTAssertTrue(scrollSettingsList(to: mac, in: app))
        mac.tap()
        let confirm = app.buttons["Đăng xuất thiết bị đó"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "no confirmation before the browser page")
        keepScreenshot("U-S6-17-devices-confirm-light-vi", of: app)
        confirm.tap()
        XCTAssertTrue(element(app, "scripted.device-sign-out-opened").waitForExistence(timeout: 3),
                      "confirming did not open the server's sign-out page")

        let recovery = element(app, "account.settings.privacy.recovery-unavailable")
        XCTAssertTrue(scrollSettingsList(to: recovery, in: app))
        XCTAssertTrue(recovery.label.contains("Khóa khôi phục, Chưa thiết lập"), recovery.label)
        keepScreenshot("U-S6-17-recovery-off-light-vi", of: app)
        app.terminate()

        let ax = launchS6("account.devices", contentSize: Self.ax5Size)
        XCTAssertTrue(element(ax, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("devices", in: ax)
        // At AX5 the row is below the fold and the list has not built it yet.
        let axMac = element(ax, "account.settings.privacy.devices.other.0")
        XCTAssertTrue(scrollSettingsList(to: axMac, in: ax))
        assertS6TextSafe(ax)
        keepScreenshot("U-S6-17-devices-light-ax5-vi", of: ax)
        ax.terminate()

        let failed = launchS6("account.devices-failed")
        XCTAssertTrue(element(failed, "account.screen").waitForExistence(timeout: 15))
        openSettingsPage("devices", in: failed)
        let retry = element(failed, "account.settings.privacy.devices.retry")
        XCTAssertTrue(scrollSettingsList(to: retry, in: failed))
        XCTAssertTrue(failed.staticTexts["Chưa tải được thiết bị."].exists)
        keepScreenshot("U-S6-17-devices-failed-light-vi", of: failed)
        retry.tap()
        XCTAssertTrue(element(failed, "account.settings.privacy.devices.other.0").waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    @MainActor
    private func useDarkAppearance(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(requestRunner("appearance dark"),
                      "no simulator appearance runner", file: file, line: line)
    }

    @MainActor
    private func useLightAppearance() {
        requestRunner("appearance light")
    }

    @MainActor
    private func launchS6(_ name: String, disablesAnimations: Bool = true,
                          contentSize: String = S6SystemUITests.defaultSize,
                          extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (disablesAnimations ? [AtumLaunchArguments.noAnimationsFlag] : [])
            + [AtumLaunchArguments.scriptedFlag, name,
               "-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", contentSize] + extra
        app.launch()
        return app
    }

    /// The default account across the new structure: the Settings index (an editable
    /// profile, then nine pages in three groups), then the pages that hold what the
    /// old flat list showed: General (notifications, language), Help (Legal), Privacy
    /// (no recovery rows without a key or a restore) and Account (Sign out).
    @MainActor
    private func assertAccountDefault(_ app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15), file: file, line: line)
        // The profile card (FlowPhone2): name and handle, opening Account,
        // where the name is edited in place.
        let card = element(app, "account.settings.index.account")
        XCTAssertTrue(card.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(card.label.contains("An") && card.label.contains("@annguyen"), file: file, line: line)
        // The desktop's pages less Advanced (desktop-only tools); Protons,
        // Privacy and this phone fold into Account.
        for page in ["account", "assistants", "connections", "general", "help"] {
            XCTAssertTrue(scrollSettingsList(to: element(app, "account.settings.index." + page), in: app),
                          "the Settings index has no \(page) row", file: file, line: line)
        }
        XCTAssertFalse(visibleTexts(app).contains { $0.contains(":") },
                       "Settings exposed a server part", file: file, line: line)
        assertS6TextSafe(app, file: file, line: line)

        openSettingsPage("general", in: app, file: file, line: line)
        let notifications = element(app, "account.settings.general.notifications")
        let language = element(app, "account.settings.general.language")
        XCTAssertTrue(scrollSettingsList(to: notifications, in: app),
                      "the General page has no notifications row", file: file, line: line)
        XCTAssertTrue(notifications.exists && notifications.label.contains("Thông báo, Đang bật"),
                      file: file, line: line)
        XCTAssertTrue(language.exists && language.label.contains("Ngôn ngữ, Tiếng Việt"),
                      file: file, line: line)
        let labels = snapshotElements(app).map(\.label)
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "account.settings.general.notifications").count, 1,
                       "notification row is not one accessibility element", file: file, line: line)
        XCTAssertTrue(labels.contains("Thông báo") && labels.contains("Đang bật"),
                      "the visual title and value disappeared", file: file, line: line)
        closeSettingsPage(in: app, file: file, line: line)

        openSettingsPage("help", in: app, file: file, line: line)
        // AC-3's Help page is longer; at AX5 Legal is below the fold.
        let legal = element(app, "account.settings.help.legal")
        XCTAssertTrue(scrollSettingsList(to: legal, in: app), "the Help page has no Legal row",
                      file: file, line: line)
        XCTAssertTrue(legal.label.contains("Pháp lý"), file: file, line: line)
        closeSettingsPage(in: app, file: file, line: line)

        openSettingsPage("privacy", in: app, file: file, line: line)
        XCTAssertFalse(app.buttons["Khôi phục tin nhắn"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["Khóa khôi phục"].exists, file: file, line: line)
        closeSettingsPage(in: app, file: file, line: line)

        openSettingsPage("account", in: app, file: file, line: line)
        XCTAssertTrue(scrollSettingsList(to: element(app, "account.sign-out"), in: app),
                      file: file, line: line)
        assertS6TextSafe(app, file: file, line: line)
        closeSettingsPage(in: app, file: file, line: line)
    }

    @MainActor
    private func openRecoveryKey(in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15), file: file, line: line)
        openSettingsPage("privacy", in: app, file: file, line: line)
        // AC-3 folds Privacy into Account, so the row can sit below the fold.
        let row = element(app, "account.settings.privacy.recovery-key")
        XCTAssertTrue(scrollSettingsList(to: row, in: app),
                      "the Account page has no recovery key row", file: file, line: line)
        XCTAssertTrue(row.label.contains("Khóa khôi phục"), file: file, line: line)
        row.tap()
        XCTAssertTrue(element(app, "account.recovery.key").waitForExistence(timeout: 3), file: file, line: line)
    }

    @MainActor
    private func captureRecoveryKeyAppSwitcher(in app: XCUIApplication,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(waitFor(3) { springboard.state == .runningForeground },
                      "SpringBoard did not come forward", file: file, line: line)
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        start.press(forDuration: 0.08, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 1_000),
                    thenHoldForDuration: 1)
        wait(1)
        let screenshot = XCUIScreen.main.screenshot()
        app.activate()
        XCTAssertTrue(element(app, "account.recovery.key").waitForExistence(timeout: 5),
                      "the recovery sheet did not return", file: file, line: line)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "U-S6-12-account-key-app-switcher-redacted-light-vi"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    @discardableResult
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<8 {
            if target.exists && target.isHittable { return true }
            list.swipeUp()
        }
        return target.exists && target.isHittable
    }

    @MainActor
    private func labelled(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func assertNoStorePurchaseWords(_ app: XCUIApplication,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let value = visibleTexts(app).joined(separator: " ").lowercased()
        for banned in ["mua", "nạp", "top-up", "buy"] {
            XCTAssertFalse(value.contains(banned), "Store shows \(banned)", file: file, line: line)
        }
    }

    @MainActor
    private func assertS6TextSafe(_ app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let values = visibleTexts(app)
        let joined = values.joined(separator: " ")
        let lower = joined.lowercased()
        for banned in ["matrix", "hermes", " bot "] {
            XCTAssertFalse((" " + lower + " ").contains(banned),
                           "visible text contains \(banned)", file: file, line: line)
        }
        XCTAssertNil(joined.range(of: #"@[A-Za-z0-9._=-]+:[A-Za-z0-9.-]+"#,
                                  options: .regularExpression),
                     "visible text contains a raw server ID", file: file, line: line)
        XCTAssertNil(joined.range(of: #"\b[0-9]+(?:\.[0-9]+)?\s*(?:KB|MB|GB)\b"#,
                                  options: [.regularExpression, .caseInsensitive]),
                     "visible text contains a file size", file: file, line: line)
        XCTAssertFalse(values.contains { $0.contains("_") },
                       "visible text contains a raw error code", file: file, line: line)
    }

    @MainActor
    private func assertDark(_ app: XCUIApplication, screen: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let frame = app.windows.firstMatch.frame
        let value = luminance(of: app.screenshot(), at: CGPoint(x: 3, y: frame.midY))
        XCTAssertLessThan(value, 0.35, "\(screen) did not render dark", file: file, line: line)
    }

    @MainActor
    private func assertNoSystemBlue(_ app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let source = app.screenshot().image.cgImage else {
            return XCTFail("could not read screenshot", file: file, line: line)
        }
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("could not rasterize screenshot", file: file, line: line)
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let targets: [(Int, Int, Int)] = [(0x00, 0x7A, 0xFF), (0x0A, 0x84, 0xFF)]
        var matches = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if targets.contains(where: {
                abs(red - $0.0) <= 8 && abs(green - $0.1) <= 8 && abs(blue - $0.2) <= 8
            }) { matches += 1 }
        }
        XCTAssertEqual(matches, 0, "welcome contains \(matches) system-blue pixels", file: file, line: line)
    }
}

