# Wave 1 copy repin

`atum-design.lock` pins public `atum-platform/atum-desktop`
`c14d74a10098db4e0e8b7bdc60ed74b2d782d36d` (branch `feat/mobile-export-wave1`,
manifest `790c07ea44b3be26cf523598ba5d0ac5a61389e03ca22730d3c00e4becb08cab`).
That commit adds the copy wave 1 of the iPhone parity plan codes against
(49 entries) and refreshes six entries to current desktop wording. Only the
catalog, copy contract, copy inventory and manifest change; every other
vendored resource is byte-identical.

**The pinned commit must be published unchanged** (same SHA, no rebase or
squash) before this lock is valid for anyone else; until then
`scripts/import-design-exports --verify` passes only against the vendored
files, and a fresh import needs a local desktop checkout holding that commit.

Workers replacing `// PENDING-COPY:<key>` placeholders: use the keys below.
Store words live under `src.matrix.mobile-copy.mobileScreensCopy.store.*`
(copied from desktop `store/store-copy.ts`); compose a monthly price as desktop
`storePriceParts` does: `monthlyFirst` (or `monthlyFreeFirst`) then
`monthlyThen`, or amount + space + `protons` + space + `monthly`. The "unnamed"
word was already exported as `src.matrix.conversation-copy.copies.unnamed`.
No key carries a Proton paid/bonus split or a VND rate.

Verification: import from the local desktop checkout, then `--verify`
(both print the pin above); `tests/test_import_design_exports.py` (8) and
`tests/test_copy_keys_in_pin.py` (3) pass; `swift test --filter 'AtumCopyTests|AtumDesignTests|ChatCopyContractTests|SidePanelCopyTests|PrototypeCatalogTests|AtumStoreArtCatalogTests|MobileFounderTests'`
ran 626 tests with 0 failures.

| Key | en | vi |
|---|---|---|
| `shared.matrix-company-board-copy.copy.chiefOfStaff` | Chief of Staff | Chief of Staff |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosCopy.paused` | Paused | Đã tạm dừng |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosCopy.preparing` | Preparing | Đang chuẩn bị |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosCopy.ready` | Ready | Sẵn sàng |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosCopy.unavailable` | Unavailable | Hiện chưa dùng được |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosRowCopy.notAvailable` | Not available yet | Chưa sẵn sàng |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosRowCopy.open` | Open | Mở |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosRowCopy.retry` | Retry | Thử lại |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosRowCopy.settingUp` | Setting up… | Đang thiết lập… |
| `shared.matrix-first-run-copy.copies.greeting` (refreshed) | Hi %1$@, I’m %2$@. You can rename me anytime, just tell me what you’d like to call me. | Chào %1$@, mình là %2$@. Bạn có thể đổi tên mình bất cứ lúc nào, chỉ cần nói tên bạn muốn gọi. |
| `shared.matrix-first-run-copy.copies.greeting.firstName=null` (refreshed) | Hi, I’m %2$@. You can rename me anytime, just tell me what you’d like to call me. | Chào bạn, mình là %2$@. Bạn có thể đổi tên mình bất cứ lúc nào, chỉ cần nói tên bạn muốn gọi. |
| `shared.matrix-team-space-copy.copy.directMessages` | Direct messages | Tin nhắn trực tiếp |
| `shared.matrix-team-space-copy.copy.newMessage` | New message | Tin nhắn mới |
| `shared.matrix-team-space-copy.copy.newMessageHint` | Choose one person or make a group. | Chọn một người hoặc tạo nhóm. |
| `shared.matrix-team-space-copy.copy.newMessageLimit` | A group can have up to 8 other people. | Một nhóm có tối đa 8 người khác. |
| `shared.matrix-team-space-copy.copy.newMessageNobody` | No one else is in this company yet. | Chưa có ai khác trong công ty. |
| `shared.matrix-team-space-copy.copy.newMessageStart` | Start conversation | Bắt đầu trò chuyện |
| `shared.matrix-team-space-copy.copy.openConversation` | Open conversation with %1$@ | Mở cuộc trò chuyện với %1$@ |
| `shared.matrix-team-space-copy.copy.personalNotes` | Your personal notes | Ghi chú cá nhân của bạn |
| `shared.matrix-team-space-copy.copy.you` | You | Bạn |
| `src.matrix.agent-home-copy.words.livesWhere` | Lives on | Đang ở trên |
| `src.matrix.agent-home-copy.words.moveSection` | Move to | Chuyển sang |
| `src.matrix.agent-home-copy.words.moveToCloud` | Move to the cloud | Chuyển lên đám mây |
| `src.matrix.chat-copy.copies.reportPerson` | Report person | Báo cáo người này |
| `src.matrix.chat-copy.copies.reportPersonBody` | Atum’s moderators get the report. They aren’t blocked. | Đội kiểm duyệt của Atum sẽ nhận báo cáo. Người này không bị chặn. |
| `src.matrix.chat-copy.copies.reportPersonTitle` | Report this person? | Báo cáo người này? |
| `src.matrix.chat-copy.copies.reportReason` | Reason (optional) | Lý do (không bắt buộc) |
| `src.matrix.legal-copy.copy.deleteAccountConfirm` | Delete account | Xóa tài khoản |
| `src.matrix.legal-copy.copy.deleteAccountDialogBody` | Your account and its data are deleted within 30 days. | Tài khoản và dữ liệu của bạn sẽ được xóa trong vòng 30 ngày. |
| `src.matrix.legal-copy.copy.deleteAccountDialogTitle` | Delete your account? | Xóa tài khoản của bạn? |
| `src.matrix.mobile-copy.mobileScreensCopy.greeting.afternoon` | Good afternoon. | Chào buổi chiều. |
| `src.matrix.mobile-copy.mobileScreensCopy.greeting.evening` | Good evening. | Chào buổi tối. |
| `src.matrix.mobile-copy.mobileScreensCopy.greeting.morning` | Good morning. | Chào buổi sáng. |
| `src.matrix.mobile-copy.mobileScreensCopy.greeting.prompt` | What can I do for you today? | Hôm nay mình giúp gì cho bạn? |
| `src.matrix.mobile-copy.mobileScreensCopy.store.apps` | Apps | Ứng dụng |
| `src.matrix.mobile-copy.mobileScreensCopy.store.assistants` | Assistants | Trợ lý |
| `src.matrix.mobile-copy.mobileScreensCopy.store.balanceLabel` | Your Protons | Proton của bạn |
| `src.matrix.mobile-copy.mobileScreensCopy.store.discover` | Discover | Cửa hàng |
| `src.matrix.mobile-copy.mobileScreensCopy.store.featured` | Featured | Nổi bật |
| `src.matrix.mobile-copy.mobileScreensCopy.store.free` | Free | Miễn phí |
| `src.matrix.mobile-copy.mobileScreensCopy.store.get` | Get | Nhận |
| `src.matrix.mobile-copy.mobileScreensCopy.store.getWithPrice` | Get · %1$@ | Nhận · %1$@ |
| `src.matrix.mobile-copy.mobileScreensCopy.store.monthly` | / month | / tháng |
| `src.matrix.mobile-copy.mobileScreensCopy.store.monthlyFirst` | %1$@ Protons first month | %1$@ Proton tháng đầu |
| `src.matrix.mobile-copy.mobileScreensCopy.store.monthlyFreeFirst` | Free first month | Tháng đầu miễn phí |
| `src.matrix.mobile-copy.mobileScreensCopy.store.monthlyThen` | then %1$@/mo | sau đó %1$@/tháng |
| `src.matrix.mobile-copy.mobileScreensCopy.store.pets` | Pets | Thú cưng |
| `src.matrix.mobile-copy.mobileScreensCopy.store.protons` | Protons | Proton |
| `src.matrix.mobile-copy.mobileScreensCopy.store.purchased` | Purchased | Đã mua |
| `src.matrix.mobile-copy.mobileScreensCopy.store.skills` | Skills | Kỹ năng |
| `src.matrix.mobile-copy.mobileScreensCopy.store.title` | Store | Cửa hàng |
| `src.matrix.moderation-copy.copies.empty` (refreshed) | No one is blocked. | Chưa chặn ai. |
| `src.matrix.moderation-copy.copies.ignoredHow` (refreshed) | Choose Block person in a chat’s menu. | Chọn Chặn người này trong menu cuộc trò chuyện. |
| `src.matrix.moderation-copy.copies.ignoredPeople` (refreshed) | Blocked people | Người đã chặn |
| `src.matrix.moderation-copy.copies.unignore` (refreshed) | Unblock | Bỏ chặn |
