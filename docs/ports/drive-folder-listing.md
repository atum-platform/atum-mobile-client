# iPhone Drive folder listing

The phone rejected the entire Graph listing when an ordinary OpenCloud file
omitted `webDavUrl`. OpenCloud 7.2.5 returns exactly that shape. On the phone,
the resulting `invalidResponse` renders “Your files are kept. Try again.”
A folder-only root can succeed while a folder with a single regular file fails.
This is a reproducible phone-side contract mismatch. Its role in the owner's
production incident still needs an authenticated device check, especially for
folders with no files.

## Source evidence

- OpenCloud's root and by-ID children handlers both call `formatDriveItems`.
  Its item formatter emits `id`, size, name, ETag, the parent reference when
  available, and the file or folder facet. It emits `webUrl` for the UI and
  omits `webDavUrl` for ordinary items. The Graph formatter and the vendored
  storage and ID code are identical across 7.2.4 and 7.2.5. At mobile base
  `b9cab0d`, `DriveClient.swift:162–172,421–424` makes the missing field a
  whole-page failure. `DriveFeatureModel.swift:627–665` and
  `ios/App/Drive/DriveScreen.swift:400–405` show the failure path to the screen.
  [Root handler](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/services/graph/pkg/service/v0/driveitems.go#L184-L215),
  [folder handler and formatter](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/services/graph/pkg/service/v0/driveitems.go#L340-L462),
  [tag comparison](https://github.com/opencloud-eu/opencloud/compare/v7.2.4...v7.2.5).
- **(a) Missing parent drive ID.** The formatter sets `parentReference.driveId`
  when the storage provider supplies a parent ID. The POSIX metadata includes
  it for normal children. The phone already gets `DrivePage.driveID` from the
  personal entry in `/me/drives` (`DriveClient.swift:67–98`) and publishes it
  to `rootDriveID` (`DriveFeatureModel.swift:547–548`). The screen constructs
  its folder route with that drive ID and the item's original ID
  (`ios/App/Drive/DriveScreen.swift:345–348,521–524,556–560`). Missing parent
  metadata therefore cannot explain a failing folder after a successful root load.
  [OpenCloud parent formatter](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/services/graph/pkg/service/v0/driveitems.go#L428-L435),
  [Reva parent metadata](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/vendor/github.com/opencloud-eu/reva/v2/pkg/storage/pkg/decomposedfs/node/node.go#L827-L854).
- **(b) ID spelling.** A normal personal drive ID is `storage$space`. OpenCloud
  strips the redundant node when building the drive's `id` and `root.id`.
  A child item ID includes its node, and its `parentReference.id` can include
  the root node. POSIX creates
  folder nodes with `uuid.New().String()`. The phone sends the drive and item
  IDs verbatim as path components (`DriveClient.swift:101–112,345–353`).
  Platform `origin/main` at `244bdbc1a651c1500ea265df498bbb771f33e172`
  publishes the Graph user-drive ID verbatim
  (`services/drive-ingress/src/provision.ts:210–219,290–295`,
  `supabase/migrations/0160_drive_identity.sql:204–232`). Ingress decodes each
  path segment once and checks the exact drive ID and the personal-space prefix
  plus lowercase UUID on the item ID
  (`services/drive-ingress/src/ingress.ts:382–389,447–476`). Its existing
  seam passes a percent-escaped own-space children request and refuses the
  matching foreign item
  (`services/drive-ingress/test/isolation-cases.ts:126–132,195–197`,
  `services/drive-ingress/test/isolation.seam.test.ts:143–157`).
  [OpenCloud drive ID](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/services/graph/pkg/service/v0/drives.go#L778-L798),
  [OpenCloud user-drive handler](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/services/graph/pkg/service/v0/users.go#L157-L204),
  [Reva resource ID format](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/vendor/github.com/opencloud-eu/reva/v2/pkg/storagespace/storagespace.go#L74-L106),
  [POSIX folder ID](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/vendor/github.com/opencloud-eu/reva/v2/pkg/storage/fs/posix/tree/tree.go#L406-L420),
  [Graph ID parser](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/services/graph/pkg/service/v0/graph.go#L145-L155).
- **(c) OIDC facts.** The three mount-bearer commits leave the OIDC subject
  lookup and ownership check intact. The mount-only branch exits at
  `services/drive-ingress/src/ingress.ts:825–856`. The OIDC branch still calls
  `activeFacts` and then `owns` at lines 857–864. The RPC request and response
  at lines 289–304 carry the same facts as before. The mapping table requires an
  ID for an active row. The RPC returns that column as `personalSpaceId`
  (`supabase/migrations/0160_drive_identity.sql:49–59,255–270`).
  The live mapping has not been read.
- **(d) Denial mapping.** Ingress sends the status and
  `X-Atum-Drive-Denial` header, then ends the response without a body
  (`services/drive-ingress/src/ingress.ts:334–338`). The closed
  `DriveDenial.decodeContract` in `DriveModels.swift:361–395` decodes a
  fixture format. Live reads already map 403 to `.denied` from the status and
  header (`DriveClient.swift:306–329`). The change maps a header-confirmed
  400 `invalid_path` to the same refusal state. A generic 400 remains
  `.invalidResponse`.

## Phone change

Keep the existing Graph requests and the personal drive ID from `/me/drives`.
Folder loading checks the account generation after the cache read before
falling back to the root's drive ID.
If a regular file lacks a DAV link, use the already-supported
`/dav/spaces/{driveID}/{path}` on the configured origin. For native POSIX
listings, the relative path comes from `parentReference.path` and the file
name. Encode each component independently and retain the existing conditional
GET, same-origin, ETag and length checks. A supplied DAV link still goes
through the URL checks. A malformed item is skipped. Credentials anywhere in
the raw payload, an unsafe supplied URL, duplicate IDs and invalid pagination
still fail the listing. No screen copy changes.
[OpenCloud WebDAV API](https://docs.opencloud.eu/docs/dev/server/apis/http/webdav/),
[OpenCloud drive DAV address](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/services/graph/pkg/service/v0/drives.go#L847-L851),
[Reva POSIX space-relative path](https://github.com/opencloud-eu/opencloud/blob/v7.2.5/vendor/github.com/opencloud-eu/reva/v2/pkg/storage/fs/posix/lookup/lookup.go#L244-L261).

## Regression coverage and live acceptance

- `testOpenCloud725FolderBrowsesAndDownloadsWithoutItemWebDavURL` uses a
  synthetic personal space, canonical folder and file IDs, and the 7.2.5
  response fields. On the base code, mapping the file throws before the
  subfolder can be shown. The fixed path checks the by-ID Graph request and
  downloads the file through the escaped DAV path with its selected ETag.
- `testRootSkipsUnusableItemsAndListsFoldersWithoutWebDavURL` exercises
  decode failures and unusable DAV paths. `testUndecodableItemsDoNotHideSecurityViolations`
  checks credential fields, cross-origin and user-info URLs, duplicate IDs
  and an invalid next link.
- `testIngressFolderDenialsUseHTTPStatusAndHeaderWithoutABody` covers the
  actual empty ingress responses. The feature model test checks folder
  navigation when the parent drive metadata is absent.

On the owner's phone, refresh Drive with an existing signed-in account. Open
a known empty folder and a folder containing an ordinary file, then open that
file. Record the HTTP status and denial reason without account identifiers or
credentials if the failure persists. A repeatable 403 `not_owner` from a
canonical folder request warrants comparing the published ID with the live
personal drive ID inside the platform. A verified mismatch belongs at the
mapping boundary in `services/drive-ingress/src/provision.ts:210–219`.
The platform fixture for that case should give the OIDC caller a stale
published ID, return a different personal ID from Graph, and assert that root
reads pass while the by-ID request is denied until the mapping is repaired.

## Hidden "."-prefixed entries (owner device report, 23 Nov 2026)

On the 23 Nov morning TestFlight build the owner saw files and folders whose names start
with "." in Drive. Ordinary files listed correctly. Desktop never lists these:
`apps/desktop/electron/matrix/drive.ts` drops every `.`-prefixed name from a
listing, and `atum-consumer-files.ts` treats them as hidden. The phone now
filters them in `DrivePage.init` (`ios/Sources/AtumNativeAPI/DriveModels.swift`),
which covers network pages, pages cached by an older build (decoding goes
through the same initialiser) and contract fixtures.
`testPagesHideDotPrefixedEntriesIncludingCachedPages` covers a fresh page and a
legacy cached page. Hidden entries still count toward the client's
`listingLimit` while paging; a folder with thousands of hidden entries could be
flagged truncated early. That is a follow-up if it ever matters.
