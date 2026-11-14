# Roster plus, short Search, notification bell (atum-desktop#48)

Desktop source: atum-desktop PR #48, merge `8fb1bd3` (14 Nov), "Roster plus
button, short Search, notification bell in the title bar". Branch
`feat/roster-plus-search-bell`, built on `feat/home-search-channels-messages-files`
(`16b10b2`), which reworks the same Home search header.

## What desktop changed

1. **New → plus.** `MatrixStartChatButton` became the Kit icon button
   (`.ak-iconbtn`, Phosphor `plus`; it was `note-pencil`) to the right of the
   roster search, with the same handler and label. Store's sidebar got the
   same treatment.
2. **Short placeholder.** `atum.roster.searchPlaceholder` is "Search" /
   "Tìm kiếm" / "検索" / "搜索" / "搜尋". The field's `aria-label` stays
   `atum.roster.search` ("Search everything").
3. **Bell.** The amber attention dot left the conversation header. A bell in
   the title bar (the New button's old place) holds `matrixAttentionItems`
   (new device to confirm, Mac sign-in/unlock/disk, Protons, runtime update,
   assistant "needs you", plan sign-in, unverified device, new sign-in) in a
   popover, with a badge dot while something needs attention.

## What maps to the phone

The phone's Home header was already the shape desktop moved to: account face,
search field, then the new-chat button to the right of the field on the same
row. So only the glyph and the copy change.

| Desktop | Phone | Where |
|---|---|---|
| New chat: Kit plus icon button right of the search | The 44 pt glass header button now draws the Kit `Plus` glyph instead of `ComposePencil`. Same action (Start chat sheet), same spoken name ("Start a chat"), same `home.create` identifier, same row. | `HomeScreen.createButton` |
| Placeholder "Search" in 5 locales | The field shows `HomeSearchPromptCopy.placeholder`: desktop's short word. | `HomeScreen.searchPrompt`, `HomeGlobalSearch.swift` |
| `aria-label` = `roster.search` | VoiceOver name stays "Search everything" / "Tìm mọi thứ". `HomeSearchField` now takes the placeholder (`prompt`) and spoken name (`label`) apart; the clear button keeps the spoken name, as before. | `HomeSearchField` |

## What does not map (and why)

- **Store's plus.** The phone's Store is a tab with a `.searchable` drawer and
  no new-chat button, so there is nothing to move. Store is untouched, so no
  Store UI tests were run.
- **Attention dot leaving the conversation header.** The phone never had
  desktop's amber dot: no `matrixAttentionItems` port exists. Nothing to remove.
- **The bell.** No phone equivalent without a product decision. See owner
  decision 1.
- **"New…" label.** Desktop's button is labelled `roster-create-copy.newMenu`
  ("New…"); the phone has always said `roster.startChat` ("Start a chat"). #48
  did not change either label, so this port keeps the phone's.

## Copy (PENDING-COPY)

The vendored export (pin `4f193a16`, before #48) carries
`desktop.atum.roster.searchPlaceholder` with desktop's retired words ("Search
chats, people, apps…" and the four translations). The key exists, so the
usual "export first, pending table if missing" rule would show the old words.

`HomeSearchPromptCopy` (`// PENDING-COPY:desktop.atum.roster.searchPlaceholder`)
holds the retired words and desktop's current words, copied from desktop's
`i18n/{en,vi,ja,zh,zh-hant}.ts` at `8fb1bd3`. The export wins unless its value
is missing, empty or one of the retired words. A repin to any desktop commit
after #48 therefore switches to the export without a code change; delete the
table in that repin. No vendored export file was edited.

| Key | en | vi | ja | zh | zh-Hant |
|---|---|---|---|---|---|
| `desktop.atum.roster.searchPlaceholder` | Search | Tìm kiếm | 検索 | 搜索 | 搜尋 |

Desktop's bell words (`attention-copy.ts` `notifications`, `nothing`) are not
needed until owner decision 1 is made.

## Owner decisions

1. **Phone notification bell — recommend: not now.** Desktop's bell exists
   because desktop has a set of account and Mac alerts with nowhere else to
   live. Most of them are Mac-only (disk, unlock, sign in again on this Mac,
   runtime update). On the phone, iOS notifications and the Home cards (the
   notification prompt, domain recovery) already cover the phone's own alerts.
   A bell would also add a fourth control to a header that already wraps to
   two rows at accessibility sizes. If the owner wants the cross-device items
   on the phone (confirm new device, unverified device, new sign-in, Protons,
   "assistant needs you"), the proposal is a bell in the Home header between
   the search field and the plus, shown only while an item exists, opening a
   sheet with desktop's list and actions. That needs a port of
   `matrixAttentionItems` (its sources and snooze/"Not now" storage) and the
   `attention-copy` keys in the export first.
2. **New-chat spoken name — recommend: keep "Start a chat".** Matching
   desktop's "New…" would make VoiceOver say an ellipsis and a vaguer word.
   Change it only if the owner wants the label identical to the desktop tooltip.

## Verification

Run once under the heavy-build lock (`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`,
`-jobs 2`, derived data `/Volumes/AtumTestFlight/dd-roster-plus`, one iPhone 17
simulator, shut down at the end):

Results:

- `xcodebuild build-for-testing` (AtumMobile, Debug, simulator): TEST BUILD SUCCEEDED.
- AtumMobileTests: 382 tests, 0 failures.
- HomeShellUITests: 25 run, 24 passed, 1 failed:
  `testInvitationMenuDeclinesOnce`. The invitation row went away during the
  1.2 s long press ("No matches found"). That test never touches the header.
  Run again on its own under the lock, it passed (1/1). Treated as a flake.
- Screenshots: `/Volumes/AtumTestFlight/roster-plus-shots/roster-plus-{en,vi}-{light,dark}.png`
  (iPhone 17, L). They show "Search" / "Tìm kiếm" in the field and the plus
  in its glass circle to the right, on the same row as the field.

What the run covered:

- `-only-testing:AtumMobileTests`: includes the new
  `HomeGlobalSearchPolicyTests.testThePlaceholderIsDesktopsShortSearchUntilTheExportCarriesIt`
  and `testThePinnedExportResolvesToTheShortPlaceholder` (the pinned export's
  value for every locale resolves to the short word; the spoken-name key is
  still exported).
- `-only-testing:AtumMobileUITests/HomeShellUITests`, skipping the three
  CI-quarantined tests: includes the new `testHeaderShortSearchAndPlusAppearances`
  (placeholder value, spoken name, plus label, plus right of the field on the
  same row; en/vi × light/dark screenshots `roster-plus-{en,vi}-{light,dark}`).
- The other attachments are exported from the result bundle to
  `/Volumes/AtumTestFlight/roster-plus-shots/attachments/`.
- `swift test` was not run: no package source (`ios/Sources`) changed.
