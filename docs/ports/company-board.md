# Company board: greeting link and the phone board (TS-10b)

Branch `feat/company-board`. Local commits only: no push, PR, CI, deploy,
signing or paid operation.

## A. Chief of Staff greeting link

Owner report (11 Nov, live phone): the private-CoS greeting showed the raw
`Open company board: https://atumplatform.com/#atum-board/<company>/<board>`
line, and a tap opened the website.

Desktop references (atum-desktop `origin/main` 583ae946):

- `apps/desktop/src/matrix/message.ts:63-104` `privateCosGreetingLinks`: only in
  a room proven company-private CoS, only an HTML `m.text` whose formatted
  body carries `<a href="https://matrix.to/#/<sender>">@Chief of Staff</a>` and
  ends `<br><br><a href="<board link>">title</a>`, and whose plain body ends
  `\n\n<title>: <board link>`.
- `apps/desktop/src/matrix/private-cos-greeting.ts` `privateCosGreetingMarkdown`:
  the bubble shows the body with the pill label and the `title: url` line
  turned into Markdown links.
- `apps/desktop/src/matrix/team-space/board-link-target.ts` `BOARD_LINK`
  (`company-ai-sdk.ts:45` uses the same form), `markdown-host.ts:46-60`
  `openMatrixMarkdownLink` (a board link in any chat is a board request, never
  the browser), `company-workspace.tsx:1631-1651` (select the company, Board
  tab, `selectedCardId`, then clear the request).
- Tests: `message.test.ts:92-125`, `private-cos-greeting.test.tsx`,
  `markdown-host.test.tsx` (board and `/card/<id>` targets).
- Link form: `apps/desktop/shared/matrix-company-private-cos.ts:363-377`.

Phone:

| Piece | Where |
| --- | --- |
| Board link parser (`CompanyBoardLinkTarget.parse`, desktop regex; `\z` is JS `$`) and greeting parser/projection (`PrivateCosGreeting`) | `ios/Sources/AtumChat/CompanyBoardLink.swift` |
| `ChatItem.privateCosGreeting`, `ChatItem.markdownBody` (Copy still copies `body`) | `ios/Sources/AtumChat/ChatItem.swift` |
| `RoomContext.isCompanyPrivateCos`, set from the platform's private-CoS binding (`CompanyRoomClassification.privateCos`), the phone's equivalent of desktop's room-state proof | `RoomKind.swift`, `LiveAppModel.conversationInfo` |
| The mapper reads the SDK's HTML `formatted` body (edit already applied) only in that room | `App/Chat/SDK/ItemMapper.swift` |
| Parse cache, bubble (including the chat-search highlight path), VoiceOver links, long-press preview and Select text render `markdownBody` | `TimelineController.swift`, `MessageBubbleRow.swift`, `MessageMenu.swift` |
| Any chat link tap: an exact board link goes to `onOpenCompanyBoard` before `LinkPolicy` | `App/Chat/Views/SafariView.swift` (`ChatLinkRouter.open`), `ChatScreen.swift` |
| Board request (desktop `$companyBoardLinkRequest`): serial + target; Team space selects the company once listed, shows Board with the card, then clears it | `CompanyWorkspaceModel.requestBoardLink/clearBoardLink`, `CompanyWorkspaceViews.swift` `applyBoardLink`, `AppRoot.swift` |

Behaviour: the greeting shows the `@Chief of Staff` link and a link titled with
the event's own text ("Open company board", or "How to use your company space"
for the card fixture); no title is invented. The pill opens
`https://matrix.to/#/<CoS>` in the in-app browser, as desktop hands it to the
browser. The board link opens Team space → that company → Board (and the card
when the link names one). A board link in any other chat is intercepted the
same way; its text stays as its author wrote it (desktop renders it the same).
A board link for a company this account does not list does nothing and waits,
as desktop's request does. Lookalike origins, uppercase IDs or extra characters
are ordinary web links (tests).

No copy was added for A: both visible strings are the event's own text.

Tests (A): `ios/Tests/AtumChat/CompanyBoardLinkTests.swift` (6 tests, against
the vendored frozen fixtures
`docs/contracts/provider/company-private-cos/v1.2/fixtures/greeting.matrix-content*.json`):
board/card parsing, lookalikes, both greetings, rendered text has no
`https://` or `<a`, exactly two links, and every departure from the frozen
shape is an ordinary message. `swift test --filter AtumChatTests`: 619 tests,
0 failures.

Not verified (A): the App target was not built here (no xcodebuild by rule);
the change was `swiftc -parse`d. No UI test: the scripted chat host has no
private-CoS room binding, so a UI test would need a new scripted company and
binding seam; left for the device round.
