import AtumChat
import XCTest

/// Store acquisition over the scripted synthetic `StoreCommerceAPI`
/// (`App/Debug/StoreScriptedCommerce.swift`). No client, account or Protons
/// are involved; the host keeps every write in memory.
final class StoreCommerceUITests: TranscriptUITestCase {
    private static let ax5Size = "UICTContentSizeCategoryAccessibilityXXXL"
    private static let delivered = "Sản phẩm đã sẵn sàng sử dụng."
    private static let insufficient = "Không đủ Proton để mua mục này."
    private static let uncertain = "Cửa hàng chưa trả lời nên chưa biết Proton của bạn đã bị trừ hay chưa. Bấm Kiểm tra trạng thái trước khi mua lại: nếu đã thành công bạn sẽ thấy ngay, nếu chưa thì bạn không bị trừ."
    private static let owned = "Đã sở hữu"
    private static let skillOwned = "Trợ lý này đã có kỹ năng."
    private static let renewalCancelled = "Đã hủy gia hạn. Quyền truy cập còn đến ngày hiển thị."

    @MainActor
    func testDetailReviewConfirmSucceedsOnce() {
        let app = launchStore("store.acquire")
        openItem("pet/gigi", in: app)
        let acquire = element(app, "store.detail.acquire")
        XCTAssertTrue(acquire.waitForExistence(timeout: 5))
        XCTAssertEqual(acquire.label, "Mua · 90 Proton")
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
        // A second press while the first write works must not send again.
        if confirm.exists && confirm.isHittable { confirm.tap() }
        XCTAssertTrue(app.staticTexts[Self.delivered].waitForExistence(timeout: 5))
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
    func testInsufficientBalanceIsPlainWithNoTopUp() {
        let app = launchStore("store.insufficient")
        openItem("pet/gigi", in: app)
        XCTAssertTrue(app.staticTexts[Self.insufficient].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "store.detail.balance").exists)
        XCTAssertFalse(element(app, "store.detail.acquire").exists, "no acquire action without the balance")
        assertNoTopUp(app)
        keepScreenshot("U-Store-4-insufficient-light-vi", of: app)
    }

    @MainActor
    func testUncertainOffersOnlyCheckStatusThenRecovers() {
        let app = launchStore("store.uncertain")
        openItem("pet/gigi", in: app)
        let acquire = element(app, "store.detail.acquire")
        XCTAssertTrue(acquire.waitForExistence(timeout: 5))
        acquire.tap()
        element(app, "store.review.confirm").tap()
        XCTAssertTrue(app.staticTexts[Self.uncertain].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "store.review.confirm").exists, "an unanswered write must not offer a new purchase")
        let check = element(app, "store.review.check")
        XCTAssertTrue(check.exists)
        keepScreenshot("U-Store-5-uncertain-light-vi", of: app)

        check.tap()
        XCTAssertTrue(app.staticTexts[Self.delivered].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts[Self.owned].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts[Self.skillOwned].waitForExistence(timeout: 3))
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
        let confirm = app.buttons["Xác nhận"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
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
    private func launchStore(_ name: String, contentSize: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [AtumLaunchArguments.noAnimationsFlag, AtumLaunchArguments.scriptedFlag, name,
                               "-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
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

    /// Guideline 3.1.1: nothing in the Store points to buying Protons.
    @MainActor
    private func assertNoTopUp(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let value = visibleTexts(app).joined(separator: " ").lowercased()
        for banned in ["nạp", "top up", "top-up", "mua proton"] {
            XCTAssertFalse(value.contains(banned), "Store shows \(banned)", file: file, line: line)
        }
    }
}
