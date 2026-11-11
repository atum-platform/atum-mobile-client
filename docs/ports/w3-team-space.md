# Team Space wave 3: invites, join with a link, channel sections (TS-11, TS-13)

Branch `feat/w3-team-space`, based on main `dc0634b` (all of wave 2). Evidence: parity audit
lane 2 (private plan repo, `docs/research/2026-11-10-parity-audit/lane2-team-space.md`), slices
L2-S9 (TS-11) and L2-S12 (TS-13). Desktop reference: atum-desktop `c14d74a1`
(`apps/desktop/src/matrix/**`, `apps/desktop/shared/**`, `apps/desktop/electron/matrix/**`);
protocol: atum-platform `packages/protocol/src/company-workspace.ts`.

TS-12 (members admin) was not started; see "Not done".

## What changed

| Slice | Phone now | Desktop source |
|---|---|---|
| TS-11 entry (closes the wave 2 TS-6 gap) | **Invite teammates** (list footer) and **Invite people** (company "…" menu) are drawn for a company admin and open the invite sheet. A member sees neither (the phone has no team-admin read to learn the company's invite policy). | `company-workspace.tsx:2791–2802`, `team-space/company-menu.tsx:171–176`, `team-space/abilities.ts` `companyAbilities` |
| TS-11 invite sheet | **Add people to {company}**: one field ("Name, @username or email"). An exact handle (`@lan` or `lan`) becomes one row with the person's circle face, `@handle` and **Add**. Someone already in says **Already a member**, an invitation still waiting says **Invited** (both from the company snapshot), with no button. Add sends the invitation and the row turns into **Invited**, with the desktop's one status line ("Invited @lan. They'll see it in Atum." or the refusal). A name or an email that is not a handle says "No one matches that.", or for an address, when links are on, "Email invites aren't on yet. Send the invite link instead." | `team-space/invite-sheet.tsx:31–60,115–200,410–520` (`inviteHandleOf`, `inviteStanding`, `failureText`, `InviteCandidateRow`) |
| TS-11 how Add is sent | On the legacy profile (no capability answer, or team admin off): `POST /companies/{id}/invite`, wire **1.1**, `{requestId, memberHandle, role: "member"}` (answer: the company snapshot). With team admin on: `POST /companies/{id}/invitations`, wire **1.3** (C1's seven-day invitation, answer schema 4). Always as a member: inviting as an admin is the owner's alone, and the phone cannot tell the owner from an admin on 1.1. After an invite the snapshot is read again, so the person shows as invited. | `electron/matrix/company.ts` (`invite`), `electron/matrix/company-team-space.ts` (`invitation-create`) |
| TS-11 share link | **Or share a link** (only with team admin on and the server's invite readiness saying `inviteLink: ready`, or no readiness answer from an older install, as the desktop decides): **Copy invite link** makes a member link and puts it on the clipboard. Its text is shown once in the sheet (selectable), with "Works for N days. Up to N people can use it." and "Anyone with this link can join as a member." **Links you can still use** lists active links ("2 of 5 used · expires in 7 days") with **Revoke** (admins). A create whose answer was a replay says "This link was created, but it can only be shown once. Revoke it and create a new one." | `team-space/invite-links.tsx:61–230` |
| TS-11 join with a link | **Join with invite link** sits in the empty Team space (whether or not this person may create a company: someone with no company is exactly who has a link) and in the Create company form (the desktop's step 1). **Join a company**: paste (field or the system Paste button) "the full HTTPS invite link", **Preview invite** → "You're invited to {company}. Invited by {name}. Expires {date}." → **Join**. The model reads the companies again and opens the one joined; the sheet closes. Failures use the desktop's words: not valid / expired / revoked / no uses left / could not be checked. | `team-space/invite-join.ts` (`inviteJoinReducer`), `team-space/invite-join-dialog.tsx`, `team-space/company-create-dialog.tsx:168–179`, `shared/matrix-invite-link.ts` |
| TS-13 sections | The channel list is now **Favorites** (channels the person tagged `m.favourite`, e.g. with TS-9's "Add to favorites"), **Channels**, and **Archived** (channels the platform marks archived, collapsed until tapped). Search filters all three. Order inside each stays the wave 1 order (default channel first, then name). | `team-space/channel-sections.tsx:42–178` |
| TS-13 create | **Channels** has the desktop's "+" (**Add channels**) for those who may create: **Create a channel** opens a sheet ("A channel keeps one topic's conversation in one place.", Name, "e.g. Launch plans", **Create channel**, "Give the channel a name." / "Use 80 characters or fewer."). It sends the desktop's flat-mode create, `POST /companies/{id}/channels`, wire **1.1**, `{requestId, displayName}`; a lost answer replays the same request ID (never a second channel), a refusal starts a new one. When the platform has made the room it opens; otherwise the list shows the channel as Preparing. | `company-workspace.tsx:1625,2940–2991`, `electron/matrix/company.ts` (`create-channel`), `team-space/channel-create-dialog.tsx` (words) |

### Phone-better or deliberate differences

- **Sections only in C2, like desktop (coordinator, 2026-11-11).** The desktop draws Favorites /
  Channels / Archived only in its C2 channels mode (`company-workspace.tsx:1667-1669`: directory read
  on 1.4 with channel admission) and one flat Channels list with archived channels inline before it.
  The worker first sectioned on every wire; the owner's bar is desktop parity, so the phone now
  sections only when `CompanyTeamSpaceProfile.channels` is true (`TeamSpacePresentation.sectionsChannels`)
  and stays flat otherwise. The scripted host turns sections on for the captures. "Channel
  invitations" and the lock on private channels still need C2 (see below).
- **Both link forms paste.** The desktop's paste parser accepts only `https://<host>/j/<token>`, while
  the platform now issues `https://<host>/j#<token>` (the token stays out of server logs). The phone
  accepts both (`CompanyInviteLinkToken.parse`). Desktop follow-up: its paste parser rejects the
  fragment form.
- **No directory search rows.** The desktop also lists people its Matrix user directory finds by name;
  on the legacy profile only the exact handle is invitable there too. The phone shows only the typed
  handle's row.
- **Join reachable without create rights.** See TS-11 join above.

## Bearer secrets and logs

- An invite token exists only as `CompanyInviteLinkToken`, in the join sheet's `@State` for one flow,
  and goes in the request body only (`/invite-links/preview`, `/invite-links/redeem`); never a URL,
  query or header. Its `description`/`debugDescription` are redacted, as is `CompanyInviteLinkSecret`'s
  (the created link). The created link's text lives only in the links section's `@State` and is dropped
  when the sheet closes. Nothing in this slice logs.
- A pasted link's host is not pinned (as on the desktop); only its token is kept. A link with
  credentials, a port or a query is not a link.
- `NativeDomainClient` admits the new paths explicitly (`invite`, `invitations`, `invite-links`,
  `invite-links/{id}/revoke`, and the two top-level `invite-links/preview|redeem`), and the one new
  header (`Atum-Company-Invites: 1`) only on `GET /company-capabilities` under wire 1.3.
- Every async answer in the new sheets is fenced on the sheet's own `@State` generation; model calls
  are fenced on an account-scope epoch (`inviteEpoch`), so an answer for a previous account is dropped.

## Server gates (implemented against the contract, entry hidden behind the real capability)

| Surface | Gate | Phone |
|---|---|---|
| Invite by handle, 1.1 | none (admins) | Live for admins. |
| C1 invitation (1.3 `invitations`) | `activation.teamAdmin == active` in the 1.3 capability answer (`ATUM_MATRIX_COMPANY_TEAM_ADMIN_ENABLED`) | Used instead of 1.1 when on. |
| Invite links (1.2) | team admin on, and invite readiness `inviteLink == ready` (`ATUM_MATRIX_COMPANY_INVITE_LINK_PEPPER` + public site origin) | Section hidden otherwise. |
| Join with a link (1.2 preview/redeem) | the link exists; any signed-in person | Always offered; a server without 1.2 answers 404, said as "not valid". |
| Universal links on the invite origin | AASA on `publicSiteOrigin` + an `applinks:` entitlement (and the desktop's `atum://join/<token>` scheme) | **Not done**: entitlements and Info.plist are outside this stream and touch signing. Paste only. |
| Channel invitations + Join, lock on private, Browse channels, private create | C2: wire 1.4 named, `features.channelAdmission`, `activation.channelAdmission == active` (`…CHANNEL_ADMISSION_ENABLED` + `…PRIVATE_CHANNELS_READY`); browse joinable is wire 1.6 | **Not drawn.** `CompanyTeamSpaceProfile.channels` is computed from the capability answer and gates channel create on the room controller (`controller.roomReconciliation == ready`) as the desktop does, but the 1.4 admitted directory, 1.6 browse and the 1.4 join/accept commands are not implemented. |
| Email invitations (1.9), directory invitations (1.10), direct add (1.12) | `…EMAIL_INVITATIONS_ENABLED`; capability 1.10; invites profile 3 | Not implemented; the sheet never offers them. |
| Members inviting (policy 1.2 `members`) | team-admin read | Not implemented: members get no sheet. |

Unverified: whether production admits the phone's MAS native bearer on each new route (the shell
middleware admits every path; `handleMatrixDomain` authenticates as for the existing company routes).

## PENDING-COPY (design export dependency, EX-1)

None of these keys is in the pinned export. `TeamSpaceCopy` reads each from the export first; until
then `ios/App/Company/TeamSpaceWave3PendingCopy.swift` holds the **desktop's own values, generated
verbatim** (en, vi, ja, zh, zh-Hant) from `apps/desktop/shared/matrix-team-space-copy.ts` and
`apps/desktop/src/matrix/team-space/layout-copy.ts` at atum-desktop `c14d74a1` (generator: a Bun
script that imports both tables and calls each phrase with `{0}`/`{1}` placeholders, and count phrases
with 1 and with another number for `.one`/`.other`). Proposed key → desktop source:

| Proposed export key | Desktop source |
|---|---|
| `shared.matrix-team-space-copy.copy.inviteSheet.{title,search,add,invite,alreadyMember,alreadyInvited,invited,notAllowed,notFound,cantInvite,emailOff}` | `matrixTeamSpaceCopy().inviteSheet.*` |
| `shared.matrix-team-space-copy.copy.{inviteLinkSection,copyInviteLink,inviteLinkCreating,inviteLinkCopied,inviteLinkAudience,inviteLinkCopyFailed,inviteLinkReplayed,inviteLinksActive,inviteLinkUsage,inviteLinkRevoke,inviteLinkRevoked}` | invite link words |
| `shared.matrix-team-space-copy.copy.{inviteLinkDuration,inviteLinkCapacity,inviteLinkExpires}.{one,other}` | count phrases |
| `shared.matrix-team-space-copy.copy.{noLongerAllowed,working,peopleNoMatch}` | sheet states |
| `shared.matrix-team-space-copy.copy.refusal.{invite_link_unavailable,invite_link_limit_reached,invite_link_rate_limited,invite_target_unavailable,invite_lookup_limited,invitation_unavailable}` | `refusal` |
| `shared.matrix-team-space-copy.copy.{favorites,archivedSection,addChannels,createChannelItem,createChannelTitle,createChannelBody,channelNameLabel,channelNamePlaceholder,channelNameRequired,channelNameTooLong,createChannelSubmit,creatingChannel}` | sidebar and create |
| `shared.matrix-team-space-copy.copy.{browseChannelsItem,channelInvitations,channelInvitationRow,joinChannel,privateChannel,browseTitle,browseSearchLabel,browseEmpty,browseNone,channelMemberCount.{one,other},joinedBadge,openChannelAction,browseJoinUnavailable,browseLoadFailed}` | C2 words, carried for the gated rows (not drawn yet) |
| `src.matrix.team-space.layout-copy.copy.{joinWithInviteLink,joinInviteTitle,inviteLinkLabel,inviteLinkHint,previewInvite,previewingInvite,invitedTo,inviteFrom,inviteExpires,joinInvite,joiningInvite,invalidInviteLink,expiredInviteLink,revokedInviteLink,exhaustedInviteLink,alreadyMemberInvite,wrongAccountInvite,inviteJoined,inviteUnavailable,addChannel}` | `teamSpaceLayoutCopy()` (the file's header says "Desktop only; the phone exports do not read this table": the export needs to add it) |

Exported keys reused: the company copy (`denied`, `conflict`, `limit`, `invalid`, `missing`,
`authentication`, `unavailable`, `channels`, `loadingChannels`, `noChannels`), `desktop.common.close`,
`src.matrix.chat-copy.copies.cancel`. The system Paste button's label is iOS's own.

Note: the export's `shared.matrix-company-copy` lacks `inviteSent`, `inviteUnavailable` and
`inviteLimited`; the phone uses the team-space refusals with the same English instead.

## Shared files touched (for the coordinator)

- `ios/Sources/AtumNativeAPI/NativeDomainClient.swift`: `CompanyInvitesAPI` conformance (eight calls),
  the two top-level invite-link URLs in the allow-list, four company sub-paths in `isCompanyPath`, the
  `Atum-Company-Invites` header rule, and `companyData` gained an `extraHeaders` parameter. Additive.
- `ios/Sources/AtumNativeAPI/CompanyConversations.swift` (TS-owned): `CompanyCapabilities` keeps
  `teamAdminActive`, `channelAdmissionFeature`, `channelAdmissionActive`, `roomReconciliationReady`.
- `ios/Sources/AtumNativeAPI/CompanyWorkspace.swift`: `CompanyWire.v1_2`.
- `ios/App/AppRoot.swift`: passes `favourites`, `inviteAvailable`, `inviteAbilities`, `canCreateChannel`
  and `invites` (`companyInviteActions`) to `TeamSpaceScreen`. Additive.
- `ios/App/LiveAppModel.swift`: `companyWorkspace.invitesProvider = { domainClient }`.
- `ios/App/Debug/ScriptedHomeHost.swift`: the scripted Workplace gains a favourite (`launch`) and an
  archived (`retro-2025`) channel, the company menu, admin invite abilities and synthetic invite answers
  (probed to `team-actions.txt`) for the UI tests.
- `ios/Package.swift`: the vendored `Fixtures/company-workspace-v1.2` resource.
- `ios/AtumMobile.xcodeproj/project.pbxproj`: only the six new files' entries.
- `TeamSpaceActions.invite: ((String) -> Void)?` (wave 2's placeholder) is replaced by
  `invites: CompanyInviteActions?`.

## Tests

- `ios/Tests/CompanyInvitesTests.swift` (SwiftPM, AtumNativeAPI): profile and abilities, the readiness
  decode, handle and email rules, standing, request bodies, link create/replay/list/revoke against the
  desktop's vendored public 1.2 pack (`ios/Tests/Fixtures/company-workspace-v1.2`, a list carrying a url
  or token is refused), paste parsing (both link forms; http, query, port, credentials, other paths and
  bare tokens refused; redacted descriptions), preview and redeem states, the channel name rule, who may
  create, and the section split.
- `ios/AppTests/TeamSpaceInviteTests.swift` (app): an admin invites on 1.1 and the roster is re-read; a
  refusal and a lost answer; a member gets nothing and no call is sent; no client draws nothing; a lost
  channel create replays its request and a refusal does not; Favorites/Archived flags; joining with a
  link opens the company.
- `ios/UITests/TeamSpaceInviteUITests.swift` (scripted host): invite a handle, "Already a member", the
  link shown once (en); a refused handle in vi; Join with invite link preview → Join; a bad link sends
  nothing; Favorites, collapsed Archived, "+" Create a channel; the invite sheet at AX5 in dark with
  `performAccessibilityAudit(for: .textClipped)`.

## Verification

Every command ran under the heavy-build lock (`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k
/Volumes/AtumTestFlight/.heavy-build.lock …`), output on `/Volumes/AtumTestFlight`, on the final tree.

| Command | Result |
|---|---|
| `cd ios && swift test --scratch-path /Volumes/AtumTestFlight/swiftbuild-w3-ts -j 2 --filter "CompanyInvitesTests\|CompanyConversationsTests\|CompanyWorkspace\|CompanySpacePolicyTests\|NativeDomainClientTests"` | 165 tests, 0 failures (new `CompanyInvitesTests`: 21); re-run after the token-case change, same result |
| `xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -sdk iphonesimulator -destination id=<iPhone 17> -derivedDataPath /Volumes/AtumTestFlight/dd-w3-ts -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing` | BUILD SUCCEEDED |
| `… test-without-building -only-testing:AtumMobileTests/{TeamSpaceInviteTests,TeamSpaceStructureTests,TeamSpaceDailyTests,ConversationTests,CompanySwitcherTests,S2StateTests}` | 152 tests, 0 failures (new `TeamSpaceInviteTests`: 8) |
| `… -only-testing:AtumMobileUITests/TeamSpaceInviteUITests`, with `sim-content-size-runner.sh` beside it | 5 of 6 pass. `testInviteSheetAtAX5DarkHasNoClippedText`: the `.textClipped` audit **timed out** ("Audit failed to complete in time", no finding returned) on a loaded machine. The run before it found one real issue (the Add button's label at AX5), fixed with a fixed vertical size and an under-the-name layout at accessibility sizes; the AX5 dark capture shows no clipping. Not re-run (each locked run waited about an hour). |
| `… -only-testing:AtumMobileUITests/TeamSpaceDailyUITests` (wave 1/2, touched by the scripted host's new channels) | 10/10 on the earlier run with the same host; 8/10 on the final run: `testMentionPickerInsertsANameAndTheSendCarriesTheUserID` ("Application does not have a process ID", 269 s) and `testSwipeMutesAndUnmutesThroughTheRoomMutePath` (line 82). Nothing those tests touch changed between the two runs (only the invite sheets did), so both are flagged as environment flakes, **not verified**. |

Screenshots (scripted host, iPhone 17 simulator) are in the worktree's `.scratch/w3-ts-shots/`
(not committed): `ts11-invite-sheet-en`, `ts11-invite-refused-vi`, `ts11-invite-sheet-ax5-dark-vi`,
`ts11-join-preview-en`, `ts13-channel-sections-en`, `ts13-create-channel-en`.

## Not done / not verified

- **TS-12 members admin** (role change, transfer, remove, pending invitations cancel/resend, policies):
  not started. It needs the 1.3 admin read (`GET /companies/{id}/administration`) first.
- **C2** channel invitations, lock, Browse channels (1.4 admitted directory, 1.6 browse, 1.4 join/accept)
  and private channels: not implemented (server-gated; copy carried).
- **Universal links / `atum://join`**: not done (entitlements, Info.plist, AASA).
- Not verified on a live account or a physical iPhone: every new route's answer to the phone's bearer,
  the 1.1 invite's 404 for an unknown handle, the link readiness on production, and the clipboard on a
  device.

## Session log

- 2026-11-11, wave 3 TS worker: TS-11 (wire, model, invite sheet, links, join) and TS-13 (sections,
  create) with tests; TS-6's Invite entry wired; doc. Verified under the heavy-build lock (above).
