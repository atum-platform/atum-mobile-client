import AtumChat
import XCTest

/// Store acquisition over the scripted synthetic `StoreCommerceAPI`
/// (`App/Debug/StoreScriptedCommerce.swift`). No client, account or Protons
/// are involved; the host keeps every write in memory.
final class StoreCommerceUITests: TranscriptUITestCase {

    /// Long copy can't be an XCUIElementQuery subscript (identifier length cap).
    @MainActor
    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    private static let ax5Size = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let delivered = "Sản phẩm đã sẵn sàng sử dụng."
    private static let insufficient = "Không đủ Proton để mua mục này."
    private static let uncertain = "Cửa hàng chưa trả lời nên chưa biết Proton của bạn đã bị trừ hay chưa. Bấm Kiểm tra trạng thái trước khi mua lại: nếu đã thành công bạn sẽ thấy ngay, nếu chưa thì bạn không bị trừ."
    private static let owned = "Đã sở hữu"
    private static let topUpComplete = "Proton của bạn đã sẵn sàng."
    private static let skillOwned = "Trợ lý này đã có kỹ năng."
    private static let renewalCancelled = "Đã hủy gia hạn. Quyền truy cập còn đến ngày hiển thị."

    @MainActor
    func testDetailReviewConfirmSucceedsOnce() {
        let app = launchStore("store.acquire")
        openItem("pet/gigi", in: app)
        let acquire = element(app, "store.detail.acquire")
        XCTAssertTrue(acquire.waitForExistence(timeout: 5))
        XCTAssertEqual(acquire.label, "Nhận · 90 Proton")
        XCTAssertTrue(element(app, "store.detail.balance").exists, "the fresh balance sits under the price")
        assertNoTopUp(app)
        keepScreenshot("U-Store-1-detail-light-vi", of: app)

        acquire.tap()
        XCTAssertTrue(element(app, "store.review").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "store.review.price").label.contains("90 Proton"))
        let balance = element(app, "store.review.balance").label
        XCTAssertTrue(balance.contains("120 Proton"), "current balance missing: \(balance)")
        XCTAssertTrue(balance.contains("30 Proton"), "resulting balance missing: \(balance)")
        keepScreenshot("U-Store-2-review-light-vi", of: app)

        let confirm = element(app, "store.review.confirm")
        confirm.tap()
        // A second press while the first write works must not send again. The
        // write may already have finished and removed the button, so press the
        // same point from one snapshot instead of re-querying it.
        if let frame = try? confirm.snapshot().frame, !frame.isEmpty {
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        }
        XCTAssertTrue(text(app, Self.delivered).waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "store.review.confirm").exists)
        keepScreenshot("U-Store-3-success-light-vi", of: app)
        element(app, "store.review.done").tap()

        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 3))
        let row = element(app, "store.item.pet/gigi")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.label.contains(Self.owned), "row should say Owned: \(row.label)")

        element(app, "store.purchased.entry").tap()
        XCTAssertTrue(element(app, "store.purchased").waitForExistence(timeout: 3))
        let records = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "store.purchased.purchase."))
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(records.count, 1, "single-flight confirm recorded more than one purchase")
    }

    @MainActor
    /// Short of Protons (lane 4 D14): the item offers the in-app top-up; a
    /// credited pack returns with Continue to the item, which can now be got.
    func testInsufficientBalanceTopsUpThenContinuesToTheItem() {
        let app = launchStore("store.insufficient")
        openItem("pet/gigi", in: app)
        XCTAssertTrue(text(app, Self.insufficient).waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "store.detail.balance").exists)
        XCTAssertFalse(element(app, "store.detail.acquire").exists, "no acquire action without the balance")
        let topUp = element(app, "topup.entry")
        XCTAssertTrue(topUp.waitForExistence(timeout: 3))
        XCTAssertEqual(topUp.label, "Nạp Proton")
        keepScreenshot("U-Store-4-insufficient-light-vi", of: app)

        topUp.tap()
        XCTAssertTrue(element(app, "topup.sheet").waitForExistence(timeout: 5))
        let buy = element(app, "topup.buy.com.atum.mobile.protons.100k")
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        assertNoEconomicMath(app)
        buy.tap()
        XCTAssertTrue(text(app, Self.topUpComplete).waitForExistence(timeout: 8))
        let finish = element(app, "topup.finish")
        XCTAssertTrue(finish.waitForExistence(timeout: 3))
        XCTAssertEqual(finish.label, "Tiếp tục")
        keepScreenshot("U-Store-12-topup-credited-light-vi", of: app)
        finish.tap()
        XCTAssertTrue(element(app, "store.detail.acquire").waitForExistence(timeout: 8),
                      "after a top-up the item can be got")
    }

    /// The Store balance opens the Proton pack sheet: each pack's total and
    /// StoreKit price only (owner ruling 1). Also the App Store Connect IAP
    /// review screenshot (`U-Store-13-pack-sheet-*`).
    @MainActor
    func testStoreBalanceOpensThePackSheet() {
        for (language, locale) in [("vi", "vi_VN"), ("en", "en_US")] {
            let app = launchStore("store.acquire", language: language, locale: locale)
            XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 15))
            let balance = element(app, "store.balance")
            XCTAssertTrue(balance.waitForExistence(timeout: 8))
            balance.tap()
            XCTAssertTrue(element(app, "topup.sheet").waitForExistence(timeout: 5))
            XCTAssertTrue(element(app, "topup.buy.com.atum.mobile.protons.100k").waitForExistence(timeout: 5))
            XCTAssertTrue(element(app, "topup.buy.com.atum.mobile.protons.500k").exists)
            XCTAssertTrue(element(app, "topup.restore").exists)
            assertNoEconomicMath(app)
            keepScreenshot("U-Store-13-pack-sheet-medium-light-\(language)", of: app)
            app.swipeUp()
            keepScreenshot("U-Store-13-pack-sheet-large-light-\(language)", of: app)
            app.terminate()
        }
    }

    @MainActor
    func testUncertainOffersOnlyCheckStatusThenRecovers() {
        let app = launchStore("store.uncertain")
        openItem("pet/gigi", in: app)
        let acquire = element(app, "store.detail.acquire")
        XCTAssertTrue(acquire.waitForExistence(timeout: 5))
        acquire.tap()
        element(app, "store.review.confirm").tap()
        XCTAssertTrue(text(app, Self.uncertain).waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "store.review.confirm").exists, "an unanswered write must not offer a new purchase")
        let check = element(app, "store.review.check")
        XCTAssertTrue(check.exists)
        keepScreenshot("U-Store-5-uncertain-light-vi", of: app)

        check.tap()
        XCTAssertTrue(text(app, Self.delivered).waitForExistence(timeout: 5))
        element(app, "store.review.done").tap()
        element(app, "store.purchased.entry").tap()
        let records = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "store.purchased.purchase."))
        XCTAssertTrue(records.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(records.count, 1, "Check status replayed the original key, never a second charge")
    }

    @MainActor
    func testOwnedRecipientAndRenewalCancellation() {
        let app = launchStore("store.owned")
        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 15))
        let pet = element(app, "store.item.pet/gigi")
        XCTAssertTrue(pet.waitForExistence(timeout: 5))
        XCTAssertTrue(pet.label.contains(Self.owned))

        pet.tap()
        XCTAssertTrue(text(app, Self.owned).waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "store.detail.acquire").exists)
        keepScreenshot("U-Store-6-owned-light-vi", of: app)
        element(app, "store.sheet.close").tap()

        // A skill is owned per assistant: Mai has it, Lan can still get it.
        openItem("skill/nova", in: app)
        let mai = element(app, "store.recipient.20000000-0000-4000-8000-0000000000a1")
        XCTAssertTrue(mai.waitForExistence(timeout: 5))
        XCTAssertTrue(mai.label.contains(Self.owned))
        XCTAssertTrue(element(app, "store.detail.acquire").waitForExistence(timeout: 3))
        mai.tap()
        XCTAssertTrue(text(app, Self.skillOwned).waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "store.detail.acquire").exists)
        XCTAssertTrue(element(app, "store.detail.open").exists, "an owned skill opens its assistant's chat")
        keepScreenshot("U-Store-7-skill-owned-light-vi", of: app)
        element(app, "store.sheet.close").tap()

        element(app, "store.purchased.entry").tap()
        XCTAssertTrue(element(app, "store.purchased").waitForExistence(timeout: 3))
        let cancel = element(app, "store.renewal.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        keepScreenshot("U-Store-8-purchased-light-vi", of: app)
        cancel.tap()
        // The dialog's Confirm shares its label with other buttons on screen;
        // tap the one the dialog put in front.
        let confirms = app.buttons.matching(NSPredicate(format: "label == %@", "Xác nhận"))
        XCTAssertTrue(confirms.firstMatch.waitForExistence(timeout: 3))
        let confirm = confirms.allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(confirm, "the renewal dialog shows a Confirm")
        confirm?.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", Self.renewalCancelled))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "store.renewal.cancel").exists)
        keepScreenshot("U-Store-9-renewal-cancelled-light-vi", of: app)
    }

    @MainActor
    func testReviewAtAccessibilitySize() {
        let app = launchStore("store.acquire", contentSize: Self.ax5Size)
        openItem("pet/gigi", in: app)
        let acquire = element(app, "store.detail.acquire")
        XCTAssertTrue(acquire.waitForExistence(timeout: 5))
        XCTAssertTrue(acquire.isHittable)
        keepScreenshot("U-Store-10-detail-light-ax5-vi", of: app)
        acquire.tap()
        let confirm = element(app, "store.review.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertGreaterThanOrEqual(confirm.frame.height, 44)
        keepScreenshot("U-Store-11-review-light-ax5-vi", of: app)
    }

    // MARK: Helpers

    @MainActor
    private func launchStore(_ name: String, contentSize: String = "UICTContentSizeCategoryL",
                             language: String = "vi", locale: String = "vi_VN") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [AtumLaunchArguments.noAnimationsFlag, AtumLaunchArguments.scriptedFlag, name,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
        return app
    }

    @MainActor
    private func openItem(_ id: String, in app: XCUIApplication) {
        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 15))
        let row = element(app, "store.item.\(id)")
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 3), "missing Store row \(id)")
        row.tap()
        XCTAssertTrue(element(app, "store.sheet").waitForExistence(timeout: 3))
    }

    /// Owner ruling 1: the pack sheet never shows a paid/bonus split or a rate.
    @MainActor
    private func assertNoEconomicMath(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let value = visibleTexts(app).joined(separator: " ").lowercased()
        for banned in ["bonus", "thưởng", "tặng", "save ", "tiết kiệm", "/ proton", "mỗi proton", "per proton", "vnd"] {
            XCTAssertFalse(value.contains(banned), "pack sheet shows \(banned)", file: file, line: line)
        }
    }

    /// Where Protons are enough, the item itself offers no top-up.
    @MainActor
    private func assertNoTopUp(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let value = visibleTexts(app).joined(separator: " ").lowercased()
        for banned in ["nạp", "top up", "top-up", "mua proton"] {
            XCTAssertFalse(value.contains(banned), "Store shows \(banned)", file: file, line: line)
        }
    }
}
