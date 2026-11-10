# Account identity truth and Delete account (AC-1, AC-2a)

Wave 1 of the iPhone parity plan, slices AC-1 and AC-2a (audit lane 5, slices S1 and S2). Desktop reference: `atum-app` `050ede8edf5`, `apps/desktop/src/matrix/**`.

## AC-1: the phone never shows a Matrix ID as a name or a handle

New Atum accounts get opaque Matrix IDs (`@user-<32 hex>`, agents `@agent-<hex>`). Before this change, the Settings profile card and Account's "Public handle" row showed the Matrix ID's localpart as the @handle, and an account with no display name used it as the *name*.

**The rule.** `Sources/AtumChat/MatrixPersonName.swift` ports desktop `person-name.ts` (`matrixPersonName`, `matrixPersonLabel`, `matrixReadableRoomName`, `isOpaqueMatrixId`, `validMatrixHandle`):

- A person's **name** is the name they set. A missing name, the Matrix ID itself, the opaque localpart (MAS's old fallback), a name made only of opaque IDs, and the SDK's ` (@id)` suffix are not names.
- An **@handle** is shown only when the alias directory said it belongs to that Matrix ID, and only when it has the directory's shape (`^[a-z][a-z0-9_]{2,31}$`). It is never derived from the Matrix ID. Even a readable early ID's localpart (`@minh:…`) is not shown as a handle, because the directory may give that handle to someone else.
- With no name, a person is called by their @handle. Without a handle, an early readable localpart is used without the "@". Failing both, the phone shows desktop's word for someone unnamed (`src.matrix.conversation-copy.copies.unnamed`, "Atum user" / "Người dùng Atum").
- Someone on another homeserver keeps their full address, as on desktop.

**Settings (desktop `rail-account.tsx` `useOwnName`/`ownHandleLine`, `settings-revamp.tsx:158-168`).** `AccountPresentation` gains `directoryHandle`, plus `profileName`, `publicHandle`, `name(unnamed:)` and `handleLine(unnamed:)`. The old `localHandle`/`name`/`showsHandle` are removed.
- The profile card shows the name, and the @handle line only when the handle adds something.
- The inline name editor no longer seeds an opaque fallback name into the field.
- The "Public handle" row appears only when a directory handle is known.

**Missing route (plan SV-4).** The phone does not read the person's own handle yet. `GET /aliases/current` is in `mobile-native-api/v1` and `AliasCurrentResponse` decodes it, but `NativeDomainClient` has no call for it, and native-bearer admission is unverified. Until that call exists, `directoryHandle` is nil in production, so the card shows no handle line and the "Public handle" row is hidden. To wire it later:
1. Add `aliasCurrent()` to `NativeDomainClient`, next to `aliasLookup`.
2. Read it once per account in `LiveAppModel`.
3. Pass the handle to `AccountPresentation(directoryHandle:)` in `AppRoot.accountPresentation`.

The handle editor (AC-11) builds on the same route.

**Other places that showed Matrix IDs (same rule):**
- `IgnoredPeopleList`: a readable localpart now reads as a name without the "@". This matches desktop. The unit test expectation was updated from `@lan` to `lan`.
- `MobileSenderLabelPolicy` (sender names, typing line): it now drops the ` (@id)` suffix and refuses an opaque localpart as a name.
- `MentionRules.candidates`: an opaque localpart is no longer offered as a mention handle.
- `LiveMatrixSession`:
  - People search and profile reads (`HomeGroupCandidate.name`), and chat members (Members page, mentions): these fell back to the raw Matrix ID and now use `PeopleNameWords.person`.
  - Room titles: these fell back to the SDK's ID-built name or the room ID. They now use the readable name, else "Atum user" for a one-to-one chat, else "Untitled chat" (`desktop.atum.roster.untitledChat`).
  - Invitation names: these are now readable or nil. `LiveRosterRows` no longer falls back to the room ID.
  - Home row sender names: these are now cleaned the same way.
- `LiveAppModel` handle lookup: a person found by @handle with no profile was named by their raw Matrix ID. They are now named `@handle`.
- `PeopleNameWords` (in `AccountModels.swift`) holds the two exported words for the Matrix session's reads, which run off the main actor. `LiveDesign.init` sets them.

## AC-2a: Delete account as an email request (desktop `legal-settings.tsx` `MatrixDeleteAccount`)

- **Settings › Account (the profile card) › Delete account…**: a neutral row under Sign out, matching desktop's placement in `settings-revamp.tsx` `AccountActions`. It is two taps from Settings.
- `DeleteAccountRequestSheet` opens a medium sheet with the title, the body, Cancel, and a destructive confirm button.
- Confirming opens a draft to `privacy@atumplatform.com`, the address in desktop `shared/atum-company.ts` `ATUM_MAILBOXES.privacy`:
  - The subject is `deleteAccountSubject`.
  - The body is `deleteAccountBody`, then a blank line, then `Atum ID: <Matrix user ID>`, in the person's language.
  - If Mail is set up, the draft opens in `MFMailComposeViewController`. Otherwise it opens through a `mailto:` link built like desktop `atumMailLink` (spaces as `%20`).
  - If neither opens (or Mail fails), the sheet shows `deleteAccountFailed`, which names the address.
- The draft logic lives in `Sources/AtumNativeAPI/AccountDeletionEmailRequest.swift`.
- `AccountDeletion.swift` (the native `atum.account-deletion/1` client) is untouched and still unused. It is kept for the full flow (AC-2b, SV-5).

## Verification

All runs used the shared heavy-build lock with `-j 2` / `-jobs 2`.

- `swift test --filter "MatrixPersonNameTests|AccountDeletionEmailRequestTests|PlainRoomsAndPushTests|MentionRulesTests|AccountDeletionTests|NativeAPITests"`: all 59 passed.
  - AtumDesignTests ran 38: MatrixPersonName 6, AccountDeletionEmailRequest 3, AccountDeletion 4, NativeAPI 9, PlainRoomsAndPush 16.
  - AtumChatTests ran 21 (MentionRules).
- `xcodebuild -scheme AtumMobileStateTests test` on the iPhone simulator compiled the app and passed 49 tests:
  - `S6PresentationTests`, 7: real handle, placeholder handle, no name.
  - `IgnoredPersonNameTests`, 1.
  - `AccountSettingsStateTests`, 16.
  - `AccountProfileEditorTests`, 25.

Not checked on a device: the Mail composer, the `mailto:` hand-off, and a live `@user-<hex>` account.

## PENDING-COPY

The pinned export does not have desktop's three dialog keys. Each placeholder reads its key as soon as the export carries it (`// PENDING-COPY:<key>` in `DeleteAccountRequestSheet.swift`). Until then it shows the closest exported wording, listed in the last column.

| Key | en | vi | Where | Interim fallback |
|---|---|---|---|---|
| `src.matrix.legal-copy.copy.deleteAccountDialogTitle` | Delete your account? | Xóa tài khoản của bạn? | Delete account sheet title | `src.matrix.mobile-copy.mobilePhoneCopy.deletionTitle` (same meaning) |
| `src.matrix.legal-copy.copy.deleteAccountDialogBody` | Your account and its data are deleted within 30 days. | Tài khoản và dữ liệu của bạn sẽ được xóa trong vòng 30 ngày. | Delete account sheet body | `src.matrix.legal-copy.copy.deleteAccountTip` |
| `src.matrix.legal-copy.copy.deleteAccountConfirm` | Delete account | Xóa tài khoản | Delete account sheet confirm button | `src.matrix.legal-copy.copy.deleteAccountAction` ("Delete account…") |

ja, zh and zh-Hant text for these keys is in desktop `src/matrix/legal-copy.ts`.

## Known follow-ups

- SV-4: the own-handle read described above. Until it lands, an owner who has a handle sees no handle line.
- Two unnamed people in one list both read "Atum user". Desktop tells them apart with a short `#abcd` tag (`matrixPersonTag`). That tag is not ported.
- The company roster still matches mention entries by localpart (`MentionRules`, company lane).
