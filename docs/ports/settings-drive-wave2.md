# Settings structure and Drive look (AC-3, AC-4)

Wave 2 of the iPhone parity plan, stream AC, slices AC-3 and AC-4 (audit lane 5, slices S3 and S4). Desktop reference: `atum-app` `050ede8edf5`, `apps/desktop/src/matrix/{settings-revamp.tsx,drive.tsx,file-glyph.tsx}` and `apps/desktop/shared/matrix-settings-revamp-copy.ts`.

## AC-3: Settings matches the desktop's pages and sections

**Index (`AccountSettingsGroupID`).** There are two quiet groups: You (Account, Assistants, Connections) and Atum (General, Help). The desktop's third group holds only Advanced. Every Advanced row is desktop-only by design: local model setup, repair of a local assistant, and the developer pages (audit §2.9). So the phone has no Advanced page. The "Manage on your Mac" rows are gone with it (audit D6).

**Destination ids stay.** Every `AccountSettingsSectionID` still opens something, as the desktop's `settingsPageOf` does. `page` maps each id to the page that draws it:
- `protons`, `privacy` and `devices` open Account. The desktop folds This Mac into Connections, but no longer draws it there. This phone's own row is in Account's devices list.
- `advanced` opens Help.

**Account page (`AccountPageSection.order`).** The order follows desktop `AccountPane` and then `PrivacyPane`:
1. The profile (no section title, as on the desktop).
2. How Atum answers.
3. Your devices.
4. Chats.
5. Memory.
6. Activity.
7. Ignored people.
8. The recovery key.
9. Sign out and Delete account….

The recovery key moves to second place when this phone must restore messages first (desktop `recovery_required`).

- **How Atum answers:** one Protons row shows the whole-Proton balance as "N left · used for Atum's built-in models and the Store", or desktop's wallet-unavailable line. The Store row stays below it. The stale "until StoreKit is ready" footer is gone (D4).
- **Top-up slot for the ST stream (ST-5):** `AccountScreen(openTopUp:)` → `AccountSettingsDetailCallbacks.openTopUp`. When it is non-nil, desktop's "Top up" button is drawn beside the balance. The ST worker passes the pack sheet at the `AccountScreen(...)` call site in `AppRoot.swift`; no other change is needed. Owner ruling 1 holds: the row shows totals only.
- **Chats:** desktop's fact row ("Kept on Atum's servers", with the per-chat encryption help) and the `encryptionDetail` footnote. This replaces the misleading "Encryption for each chat — Not available" row (D5).
- **Memory:** "Atum remembers", desktop's help line, and "Not available yet".
- **Ignored people:** always drawn, as on the desktop (D13). The list explains how ignoring works when it is empty.
- **Reports:** the two reporting switches move to Help › "Help improve Atum", where the desktop's usage switch lives.

**Connections page.** It is renamed "Connections". Desktop renamed "What Atum knows" back in `1043f1b48d7`; the pinned export still has the old words, see Copy below. It has three sections:
- Subscriptions: "Your subscription". This row moved here from Advanced and reads "Not available yet" until S8.
- Google.
- Apps: "Not available yet" until AC-5.

The old Apps section listed the Store catalog as "connected apps" and read "Apps · Connected" when empty (D2). It now says "Not available yet" until the consent route exists (SV-6, AC-5). "This iPhone" and "On your Mac" left Connections.

**General.** The page has two sections:
- Look: Appearance, Text size and Language, in the desktop's order.
- Notifications.

Startup is a macOS login item and stays on the Mac.

**Help.** The page has four sections:
- About: the version.
- Help improve Atum: the two reports.
- Contact us: Founder, or desktop's "Email support", which drafts to `support@atumplatform.com` with the exported subject (`AccountSupportMail`). This replaces the disabled "Contact Atum — not available" row.
- Legal.

**Capabilities (D3).** `AccountSettingsCapabilityStatus` maps:
- unknown → "Loading…",
- unavailable → "Not available yet",
- available → no status text.

An adapter that turns a capability on is no longer shown as "Not available".

## AC-4: Drive looks like the desktop's

- **Type glyphs (`DriveFileFamily`):** this ports desktop `file-glyph.tsx`. Families are chosen by extension only: document (including PDF), spreadsheet, presentation, image, audio, video, archive and other. `glyphAlias` maps each family to the Phosphor assets that are already bundled.
- **Recents and All files:** a segmented control at the root offers the desktop's two places. Recents is the default.
  - Recents shows the four newest items as large tiles, then the whole listing newest first (`DriveRecents`, desktop `recentDriveRows`: modified time, then name, undated items last).
  - All files keeps folders first, by name.
  - A folder tile pushes that folder.
- **Status line:** "Up to date · 14:32" shows over a fresh listing of a ready Drive (`DriveStatusLine`, `DriveDirectoryPresentation.refreshedAt`, set when a page arrives from the server). Stale, offline and sign-in notes take its place as before. Times follow desktop `formatDriveSyncTime` and `formatModified` (`DriveTimeFormat`): the time today, the date before today. File rows use the same rule.
- **Empty root:** "Nothing here yet." with "Your synced files will appear here." and a folder glyph. An empty subfolder still says "This folder is empty".

Not in this slice:
- Search and the list/grid toggle (audit P2/P3).
- Use in a conversation (lane 1).
- Upload and storage facts (server-gated by the read-only `atum.mobile-drive/1`).
- A scripted Drive debug host (D12).

## Copy owed to the export

Each fallback is read only until the export carries its key. The fallbacks are the desktop's own five-locale words at `050ede8edf5`, unless marked phone-only.

| Key | en (desktop source) | Where |
|---|---|---|
| `shared.matrix-settings-revamp-copy.copies.destinations.connections` | Connections | **Stale in the export** ("What Atum knows"). `AccountSettingsText.staleInPinnedExport` reads the desktop's words until the re-pin. |
| `…copies.howAtumAnswers` | How Atum answers | Account |
| `…copies.protonsLeft` | `{amount}` left · used for Atum's built-in models and the Store | Account, as `%1$@` |
| `…copies.topUp` | Top up | Account (ST-5 slot) |
| `…copies.walletUnavailableHelp` | Proton balance and activity will appear here when the wallet is available. | Account |
| `…copies.yourSubscription` / `subscriptionHelp` | Your subscription / Use ChatGPT, Claude or Gemini you already pay for | Connections |
| `…copies.notAvailableYet` | Not available yet | Connections, Account |
| `…copies.google`, `apps`, `otherDevices` | Google, Apps, Other devices | Connections, Account |
| `…copies.memory`, `remembers`, `remembersHelp`, `memoryDisclosure` | Memory, Atum remembers, Helps your assistants remember context between conversations., … | Account |
| `…copies.activity`, `shareActivity`, `shareActivityHelp` | Activity, Share activity, Let others see your read receipts and typing. | Account |
| `…copies.chats`, `chatsStored`, `chatsStoredHelp`, `encryptionDetail` | Chats, Kept on Atum's servers, They aren't end-to-end encrypted by default…, An encrypted chat stays out of Atum's memory… | Account |
| `src.matrix.drive-copy.matrixDriveCopy.browser.recents` / `browser.allFiles` | Recents / All files | Drive |
| `shared.matrix-settings-revamp-copy.phoneSettingsCopy.usesIOSSettings` / `opensIOSSettings` | Uses iOS settings / Opens iOS Settings | General. **Phone-only**; ja, zh and zh-Hant were written here and need copy review. |
| `…phoneSettingsCopy.shareCrashReports`, `shareCrashReportsHelp`, `shareUsageData`, `shareUsageDataHelp`, `reportingFooter` | (unchanged phone wording) | Help. Phone-only, still owed. |

The Drive empty-root body reuses `matrixDriveCopy.comingSoonHelp`. Desktop's `emptyRoot.body` says to drop files into the Mac's Drive folder, which the phone cannot do. A phone key (for example `mobilePhoneCopy.drive.emptyRootBody`) would be more precise.
