# Polish P6: one root header, Back vs X, system sheet backgrounds

Lane P6 of the iPhone polish wave. It closes UX audit issue 7 ("four tabs, four
header patterns") and the P2 proposals 1, 2, 3 and 5
(`polish-p2-lists-headers.md`). The owner approved the recommendations on
28 Nov 2026 ("go with your recommendations"), including owner decision 4 (Team
Space header) and decision 6 (the bell moves into the account face, as on
desktop).

Branch `feat/polish-p6-root-headers`, stacked on `feat/chat-parity-phone`,
because that branch's ML3 lane rebuilt Home search in the same files. ML3's
search engine and results (`HomeSearchController`, `HomeGlobalSearch`,
`HomeSearchResultsView`) are untouched: P6 only replaces the field that feeds
them.

## The rules

### Root header (every tab root)

1. **Title:** the root's exported title through `.navigationTitle`. Home,
   Drive and Store use a large title. Team Space with a company open uses the
   company name inline, because its title is the company switcher
   (`.toolbarTitleMenu`). With no company it keeps the large "Team space".
2. **Search:** the system `.searchable` in the bar's drawer
   (`.navigationBarDrawer`). No hand-built search fields.
3. **Leading:** only Home has a leading item, the account face. Account and
   Settings live behind it (desktop's rail account).
4. **Trailing:** system bar items only, no hand-drawn glass:
   - status first, and only while it says something (Store's connection glyph
     is not drawn as an empty item);
   - then the root's own controls;
   - the root's primary action or its "…" menu comes last.
   Groups that do different jobs are split with `ToolbarSpacer(.fixed)`.

| Root | Leading | Title | Trailing |
|---|---|---|---|
| Home | account face (carries the attention dot) | large "Chats" | compose (+) |
| Team Space | — | company name, title menu = switcher | view menu · Activity, "…" |
| Drive | — | large "Drive" | "…" view options |
| Store | — | large "Store" | connection glyph (only while offline) · balance |

### Back vs X (sheets and panels)

- **X only on a sheet's root page**, at `.cancellationAction`, for sheets that
  show content (the chat panel, Store item, Companies).
- **Back (the system chevron) on every page pushed inside a sheet**, with no
  X beside it. The sheet still closes by dragging it down, and on an iPad
  keyboard Escape still closes the chat panel from any page (the host keeps
  the `.cancelAction` shortcut while a page is pushed).
- Sheets that edit and save keep Cancel / Done text (the audit's rule), for
  example the assistant card's model, destinations and routines pickers.
- Never both Back and X on one level.

Applied in the chat panel (`ChatPanelHost`): the root page (`ChatInfoHome`,
which also hosts the assistant card) keeps its X. Members, Shared "See all",
an app's page, Pinned messages and the agent desk now show only Back. Before
P6 those pages had Back and an X; Pinned messages put its X at the leading
edge, where the Back belongs. The assistant card already followed the rule:
it sits on the panel's root, and in Settings › Assistants it is pushed with
Back. Its edit sub-sheets use Done.

### Sheet background

A sheet uses the system sheet background: no `.background(ground)` fill and no
`.scrollContentBackground(.hidden)` at its root, so a grouped list draws the
system grouped background and a plain one the sheet's own. Bottom action bars
inside a sheet use the system `.bar` material instead of a ground strip.

## What changed

Filled in below.
