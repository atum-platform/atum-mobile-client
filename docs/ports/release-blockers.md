# Public iPhone release blockers: REL-1, REL-9, REL-10

Verification state: **pending hosted CI**. This implementation was rebased onto
`origin/main` and committed locally on `fix/release-blockers`. The implementation
agent does not push, open a PR, launch CI, build/archive locally, or deploy.

## REL-1: shipping Release configuration

- Removed the `ATUM_DEMO_RELEASE` compile error from `AtumMobileApp.swift`.
  Release uses the existing optimized, whole-module configuration and explicitly
  defines no Swift active compilation conditions in the application target.
- Release `EXCLUDED_SOURCE_FILE_NAMES` removes every source under `App/Debug`
  and `Scripted*.swift` hosts. Existing whole-file `#if DEBUG` guards remain.
  Added the missing whole-file guard around shared `AtumChat/LaunchArguments.swift`,
  including `ScriptedScenario`; the shared scripted implementations were already
  guarded. Scenario selection is absent at compilation, rather than disabled by
  a runtime flag.
- Probe sink storage, sink installation, records, serialization and clock reads
  now compile only in Debug. Production call sites retain the constant-false
  `isEnabled` and empty `mark` interface, with no installable sink.
- `AtumDesign` formerly copied the entire producer export, including
  `fixtures/phone.json` and `fixtures/playground.json`. Its package now explicitly
  lists production resource members without the fixture directory. Logical asset
  paths are unchanged; the bundle loader follows the new root layout and the
  exposed manifest omits fixture entries. The original producer export and hashes
  are unchanged. The founder unit test reads its original input from the source
  checkout, like other contract tests. `AtumPrototype` and its separate fixtures
  are not dependencies of the app or extension.
- Debug compilation conditions and Debug scheme test actions are unchanged.
  Scripted UI scenarios remain compiled for those actions. Design fixture data
  is now a test input, rather than a production resource in either configuration.

### Private release lane compatibility

Read-only inspection of the separate release checkout's `scripts/testflight.sh`
and `docs/testflight.md` found the archive invocation uses `-scheme AtumMobile
-configuration Release` and adds only
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ATUM_DEMO_RELEASE` (script line
91). It does not add `DEBUG`. The old opt-in is now unused, so the existing lane
remains compatible even before its cleanup. No private files were edited.

Exact lane cleanup for its owner:

1. In `scripts/testflight.sh`, remove the final argument
   `'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ATUM_DEMO_RELEASE'` and the
   preceding line continuation after `CURRENT_PROJECT_VERSION="$BUILD_NUMBER"`.
   Remove the two archive comments explaining the former demo guard. Preserve
   the Release configuration, source checkout selection, build-number override,
   signing, export and validation arguments.
2. In `docs/testflight.md`, replace the "Release guard" bullet with "Release
   excludes debug hosts and fixtures at compilation/resource membership; no demo
   opt-in is required." Replace "archives Release with `ATUM_DEMO_RELEASE`" with
   "archives the production Release configuration" in the coordinator steps.

No lane change is needed to compile this patch. After hosted CI, the coordinator
should inspect the actual archive for absent fixture JSONs/debug symbols and for
both manifests plus `ThirdPartyLicences.json`; source-only checks cannot prove
final archive contents or aggregate third-party framework privacy manifests.

## REL-9: privacy manifest audit

The table abbreviates `NSPrivacyCollectedDataType` and
`NSPrivacyAccessedAPICategory` prefixes. `F` means App Functionality and `A`
means Analytics. Every declaration has tracking false and both bundles declare
no tracking domains. Stable installation/device association is treated as linked
even when no account identity is sent to analytics. The single DeviceID entry
unions PostHog analytics and the account-associated APNs token purposes.

Apple's [data type definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)
and [approved API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
were checked during the audit. Encryption has no separate manifest field; it
does not remove the content declarations here.

### App collection declarations

| Type | Linked; purpose | Declaration | Code evidence and scope |
| --- | --- | --- | --- |
| CrashData | No; F | `ios/App/PrivacyInfo.xcprivacy:13` | Sentry startup and `beforeSend`: `ios/App/Telemetry/LiveReporting.swift:243`; user/request removal: `ios/App/Telemetry/LiveReporting.swift:307`. Crash frames/type/mechanism remain. |
| OtherDiagnosticData | No; F, A | `ios/App/PrivacyInfo.xcprivacy:25` | Sentry release/build/environment: `ios/App/Telemetry/LiveReporting.swift:245`; PostHog app/build/OS/environment: `ios/Sources/AtumTelemetry/TelemetryEvent.swift:124`. These describe technical environment, rather than account identity. |
| ProductInteraction | Yes; A | `ios/App/PrivacyInfo.xcprivacy:38` | Launch, sign-in outcome and first accepted send: `ios/App/Telemetry/LiveReporting.swift:117`, `ios/App/Telemetry/LiveReporting.swift:152`, `ios/App/Telemetry/LiveReporting.swift:156`; payload installation association: `ios/Sources/AtumTelemetry/TelemetryEvent.swift:135`. |
| DeviceID | Yes; F, A | `ios/App/PrivacyInfo.xcprivacy:50` | Persisted installation UUID and derived analytics ID: `ios/Sources/AtumTelemetry/TelemetryConsent.swift:42`, `ios/Sources/AtumTelemetry/TelemetryConsent.swift:52`; APNs token in pusher registration: `ios/Sources/AtumNativeAPI/MobilePush.swift:88`; signed-in registration: `ios/App/LiveAppModel.swift:3903`. No advertising identifier. |
| Name | Yes; F | `ios/App/PrivacyInfo.xcprivacy:63` | Account display name/profile: `ios/App/Account/AccountModels.swift:76`, `ios/App/Account/AccountModels.swift:133`; account-associated member display names: `ios/Sources/AtumNativeAPI/CompanyConversations.swift:113`. |
| EmailAddress | Yes; F | `ios/App/PrivacyInfo.xcprivacy:75` | Hosted account authentication: `ios/App/MASWebAuthPresenter.swift:56`; support mail: `ios/App/Account/AccountSettingsDetail.swift:461`; deletion request email: `ios/App/Account/DeleteAccountRequestSheet.swift:79`. This conservatively covers account/support contact information received by the service, not a claim that native OIDC requests an email scope. Native scopes are only openid plus Matrix permissions: `ios/Sources/AtumNativeAPI/OIDCFlow.swift:108`. |
| UserID | Yes; F | `ios/App/PrivacyInfo.xcprivacy:87` | Account user ID and handle: `ios/App/Account/AccountModels.swift:94`; alias assignment's principal/handle/Matrix user: `ios/Sources/AtumNativeAPI/Identity.swift:128`; the handle is an account identifier, not analytics identity. |
| EmailsOrTextMessages | Yes; F | `ios/App/PrivacyInfo.xcprivacy:99` | Matrix sends/replies: `ios/App/Chat/SDK/SDKTimelineSource.swift:237`; server receives content with the room/account association. Encryption qualification below. |
| PhotosorVideos | Yes; F | `ios/App/PrivacyInfo.xcprivacy:111` | Image upload and thumbnail metadata: `ios/App/Chat/SDK/SDKTimelineSource.swift:255`; SDK attachment send: `ios/App/Chat/SDK/SDKTimelineSource.swift:277`. |
| OtherUserContent | Yes; F | `ios/App/PrivacyInfo.xcprivacy:123` | File attachment branch and SDK send: `ios/App/Chat/SDK/SDKTimelineSource.swift:271`; selected document staging: `ios/App/Chat/Media/AttachmentPreparer.swift:133`. Drive access is read-only, with no upload operation: `ios/Sources/AtumNativeAPI/DriveClient.swift:16`. |
| PurchaseHistory | Yes; F | `ios/App/PrivacyInfo.xcprivacy:135` | Verified StoreKit result includes signed transaction: `ios/Sources/AtumNativeAPI/StoreKitPurchaseStore.swift:72`; account-bound API submission: `ios/Sources/AtumNativeAPI/ApplePurchaseCoordinator.swift:246`. Card/payment credentials are handled by Apple and are not app-collected PaymentInfo. |
| CustomerSupport | Yes; F | `ios/App/PrivacyInfo.xcprivacy:147` | User-initiated support email: `ios/App/Account/AccountSettingsDetail.swift:461`; account deletion email with account ID: `ios/App/Account/DeleteAccountRequestSheet.swift:79`. The native app opens the mail composer/client; receipt at support is part of the service collection scope. |
| AudioData | Yes; F | `ios/App/PrivacyInfo.xcprivacy:159` | Dictation buffers enter Speech recognition: `ios/App/Chat/Dictation/SpeechDictationEngine.swift:390`. On-device recognition is required only when supported (line 392); the existing fallback can send audio to Apple's recognition service. Conservative functionality disclosure includes that fallback. No audio analytics is added. |

Sentry and PostHog remain independently optional/disabled when their build-time
configuration is empty (`ios/App/Telemetry/LiveReporting.swift:173`,
`ios/App/Telemetry/LiveReporting.swift:229`). The manifest describes supported
configured Release behavior, not just a checkout with empty telemetry values.
No new collection code was introduced by this patch.

**E2EE qualification:** Matrix content in encrypted rooms is end-to-end encrypted;
room encryption is read at `ios/App/Chat/SDK/SDKTimelineSource.swift:76`, and the
Matrix SDK owns the send/upload encryption path. However, the current product
also creates plain agent rooms (`ios/App/LiveMatrixSession.swift:322`) and plain
company rooms (`ios/App/LiveMatrixSession.swift:503`). Do not label all messages,
photos or files E2EE in App Store copy. The manifests retain content declarations
regardless; notification plaintext is produced locally after SDK decryption.
This patch does not change messaging encryption or claim that server-side agent
processing cannot access its own conversations.

### Required-reason API declarations

| Bundle; category | Reasons | Declaration | Code evidence and reason |
| --- | --- | --- | --- |
| App; UserDefaults | CA92.1 | `ios/App/PrivacyInfo.xcprivacy:174` | App-private telemetry preferences/installation ID: `ios/Sources/AtumTelemetry/TelemetryConsent.swift:13`, `ios/Sources/AtumTelemetry/TelemetryConsent.swift:42`; app preferences: `ios/App/DesignSystem/AtumAppearance.swift:18`. No shared UserDefaults suite was found; shared Keychain/files do not imply reason 1C8F.1. |
| App; SystemBootTime | 35F9.1 | `ios/App/PrivacyInfo.xcprivacy:182` | In-app deadlines: `ios/App/LiveAppModel.swift:1031`; typing timer: `ios/App/Chat/SDK/TypingController.swift:203`; draft/replay intervals: `ios/App/Chat/Stores/ConversationStore.swift:164`. These clocks implement timers and elapsed intervals, rather than exporting boot time. |
| App; DiskSpace | E174.1 | `ios/App/PrivacyInfo.xcprivacy:190` | Capacity reads: `ios/Sources/AtumNativeAPI/DriveCache.swift:77`; low-capacity admission/eviction: `ios/Sources/AtumNativeAPI/DriveCache.swift:238`. Changes whether a selected download can proceed. |
| App; FileTimestamp | C617.1, 3B52.1 | `ios/App/PrivacyInfo.xcprivacy:198` | Own cache file modification dates and pruning: `ios/Sources/AtumChat/ChatListSnapshot.swift:359`; own/shared store attributes: `ios/Sources/AtumNativeAPI/MatrixStoreDirectory.swift:137`; document picker security-scoped file metadata: `ios/App/Chat/Media/AttachmentPreparer.swift:133` (3B52.1). |
| Extension; FileTimestamp | C617.1 | `ios/Notifications/PrivacyInfo.xcprivacy:88` | Shared app-group store validation: `ios/Notifications/MatrixNotificationFetcher.swift:22` calls `MatrixStoreDirectory.requireExisting`; metadata checks at `ios/Sources/AtumNativeAPI/MatrixStoreDirectory.swift:53` and `ios/Sources/AtumNativeAPI/MatrixStoreDirectory.swift:137`. |

### Notification extension collection declarations

The extension's manifest covers the account/device/content boundary of its
authenticated SDK notification fetch. All entries are linked, functionality-only,
and never tracking. It adds no separate analytics or purchase/contact-email
collection. Incoming notification content remains on-device presentation; these
content entries conservatively describe the shared service's retained message
data used by the extension, not an additional upload of decrypted content.

| Type | Declaration | Code evidence |
| --- | --- | --- |
| Name | `ios/Notifications/PrivacyInfo.xcprivacy:13` | Sender/room names used for local notification text: `ios/Notifications/MatrixNotificationFetcher.swift:110`. |
| UserID | `ios/Notifications/PrivacyInfo.xcprivacy:25` | Account-authenticated SDK restore/fetch: `ios/Notifications/MatrixNotificationFetcher.swift:27`, `ios/Notifications/MatrixNotificationFetcher.swift:50`. |
| DeviceID | `ios/Notifications/PrivacyInfo.xcprivacy:37` | Matrix device ID/session restoration: `ios/Notifications/MatrixNotificationFetcher.swift:28`, `ios/Notifications/MatrixNotificationFetcher.swift:51`. This extension does not register APNs tokens itself. |
| EmailsOrTextMessages | `ios/Notifications/PrivacyInfo.xcprivacy:49` | Text/notice/emote mapping after SDK fetch/decryption: `ios/Notifications/MatrixNotificationFetcher.swift:94`. |
| PhotosorVideos | `ios/Notifications/PrivacyInfo.xcprivacy:61` | Image/video event presentation: `ios/Notifications/MatrixNotificationFetcher.swift:97`; no media download. |
| OtherUserContent | `ios/Notifications/PrivacyInfo.xcprivacy:73` | File event presentation: `ios/Notifications/MatrixNotificationFetcher.swift:100`; no file upload/download. |

The extension uses shared session files and Keychain, not UserDefaults. Its
own source does not read disk capacity or boot-time APIs. Third-party dynamic
framework reason declarations still belong in those frameworks' manifests;
hosted archive/privacy-report inspection must validate the pinned Matrix SDK
and Sentry artifacts, which were not built or downloaded for this source audit.
Backend retention and hosted authentication implementation are outside this
checkout; account-email, support and Speech fallback declarations deliberately
cover those supported flows instead of treating native model absence as proof
of no service collection.

## REL-10: complete licences screen

`LegalScreens.swift` keeps the exported navigation title
`src.matrix.legal-copy.copy.openSourceLicences`, styling and accessibility ID.
Its selectable text loads the complete bodies named by `ThirdPartyLicences.json`,
not internal `NOTICE` or the design export's internal attribution commentary.

`python3 scripts/generate-ios-licences.py` deterministically generates a component
index of existing bundled legal resources. The screen joins their complete,
verbatim retained UTF-8 bodies under readable component headings. The original
root `LICENSE` and `LICENSES/Hermes-Agent-MIT.txt` are now app resource members;
the font licence is loaded from the production design bundle. Coverage includes the Atum source terms, Matrix/Element X Apache-2.0,
Hermes MIT, Sentry MIT and third-party licences, Textual, SwiftUI Math,
Concurrency Extras, Prism, all retained math-font notices/licences (including
SIL OFL, MIT, GUST and LPPL 1.3c), and native Cormorant Garamond OFL. The SDK
licences listed in `THIRD-PARTY.json` are byte-identical to the Matrix Apache
text and are represented by that complete body. No legal source body was edited.
Legal documents may retain their original references/URLs; the screen presents
their actual terms rather than substituting repository paths for those terms.

The generated project includes the new resource and extension manifest. XcodeGen
also normalized pre-existing manually inserted project IDs/order for company
invite files; their source membership remains intact.

## Verification and handoff

- Passed: `python3 -m unittest discover -s tests -p test_ios_project_sources.py`
  (7 tests: existing source membership plus Release exclusions/flags, Debug
  scenario guards, fixture resource membership, both manifests, complete legal
  bodies and bundled resource membership).
- Passed: `swiftc -parse` for changed Swift files in Release and with `-D DEBUG`.
- Passed: `plutil -lint` for both manifests and the generated project.
- Passed: `git diff --check`.
- Passed: `bash scripts/pre-push-public origin/main HEAD` against the amended
  candidate (one new commit; identifier/secret/metadata checks passed). The initial
  local candidate was rejected because a combined licence file duplicated
  upstream author email identifiers into a new path. The final implementation
  indexes existing resource bodies instead, preserving every legal text and
  the trusted guard policy. The initial candidate is replaced by the amended
  local commit, rather than retained in the public candidate's ancestry.
- No `swift build`, `swift test`, `xcodebuild`, CI, archive, signing, upload,
  secret access, deployment or external reviewer/sub-agent was run.

Still **pending hosted CI**: Swift type-check/link of both configurations and the
extension, Swift unit/UI tests, actual resource bundle layout, and final archive
privacy aggregation. The resource-layout change and newly absent Release-only
scenario/probe types are the main compile/integration boundaries for CI to
exercise. Parse/lint success is not a successful build claim.

Coordinator addition (11 Nov, 11:15 UTC): hosted CI built only Debug, so the
`App target and AppTests` job now also builds the Release configuration for a
generic iOS device without signing. It fails if the Release `.app` contains any
`fixtures` path or lacks `PrivacyInfo.xcprivacy`. That is the build of record
for the Release-only exclusions above; it is not an archive or privacy-report
check.
