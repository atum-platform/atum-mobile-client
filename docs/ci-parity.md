# Public CI parity checkpoint

Built locally, not activated. No pushes, dispatches, settings changes or uploads.
Keep previous checks until replacements pass on the exact public head. Standard
hosted runners only; GitHub-owned actions pinned by SHA; no secrets or release authority.

## Adopted mechanisms

Extends the existing public workflow, canonical `scripts/run_tests.sh` file-isolated
runner and existing desktop import-closure checker. Raw git blob/mode validation
extends the approved snapshot mechanism to multi-commit history; gitleaks supplies
secret rules. No private source files, fixtures or manifests were copied.

## Parity table

| Previous job/lane | Public job / disposition | Coverage and limits |
| --- | --- | --- |
| tests.yml generate + test (8 slices) | hermes (8 slices) | All retained tests, canonical runner, deterministic I/8 slicing, two workers. Public lock/interpreter 3.14 vs previous explicit 3.11: interpreter parity remains to verify. |
| tests.yml e2e | python-e2e | Entire retained tests/e2e via isolated runner. |
| lint.yml ruff-blocking | python-lint | Same pinned ruff check. |
| lint.yml windows-footguns | python-lint | Same static checker over all public files. |
| lint.yml lint-diff | stays private initially | Advisory ty/ruff diff report not reproduced. Blocking lint remains public. |
| js-tests desktop check:lint | client | Typecheck, lint, private-absent import closure compilation. |
| js-tests desktop platforms / UI | client | All vitest projects, required Python seam and locked real Python environment. |
| js-tests desktop upstream-watch | client | Same retained Node test command. |
| js-tests desktop local-brain | stays private | Public package has no proof check; no copying excluded proof inputs. |
| js-tests desktop all native package/install | stays private | Packaging/release inputs excluded; renderer E2E is not installed-app verification. |
| js-tests shared, atum-kit, browser-client, device-protocol, model-client, ui-tui, hermes-ink, web | workspaces matrix | Each public package's complete check command. |
| js-tests controller/sandbox/private web/bootstrap/tests-js | stays private | Excluded source/seams. |
| e2e-desktop Linux | desktop-e2e | Full public suite, same pinned Playwright image, Electron/Xvfb, real Python. Screenshot update mode proves harness; trusted baseline comparison/evidence publishing remains uncovered. No artifact uploads. |
| ci aggregate/classifier, release/signing/provenance, private integration | stays private | Coordinator adjusts only after exact-head public proof. |
| mobile resources | mobile resources/client | Selected public importer/push checks; full resource suite depends on excluded inputs. |
| mobile swift package | mobile swift | Full public package tests on standard macos-26. |
| mobile ios-app AppTests | app-tests | Standard public `macos-26` runner discovers an available iPhone simulator, builds the app/test targets without signing, and runs `AtumMobileTests`. |
| mobile SDK custody/Apple/phone | stays private | Private SDK source packs, generated Apple frameworks and proof receipts are not public client inputs. |

## Outbound guard and bootstrap

Run `bash scripts/pre-push-public <reviewed-public-base-sha> <candidate-head-sha>`
from the candidate repo, using a trusted reviewed helper/policy, before any push.
Install gitleaks 8.30.1; CI also validates the release archive checksum. Full public
history is mandatory. Check every ref being pushed; never implicitly push tags.

The policy is a deny list, derived from the approved export boundary and its
exclusion rules. New ordinary files (including desktop components and tests) need
no policy edit. It blocks private controller/sandbox and web/bootstrap seams,
operations/internal docs/evidence, restricted productivity skills, release/signing/
publish automation, credential/generated directories and `.env*`. Symlinks and
submodules are denied; new or changed blobs have a 10 MiB size limit (including
binaries). Unchanged approved baseline blobs are grandfathered; every new commit is checked,
including intermediate files later deleted. Full-history/root checks remain.

Pinned gitleaks scans every newly reachable commit plus commit metadata with the
default rules and no candidate ignore/config/inline allowances. Secrets cannot be
adjudicated. Identifier checks cover personal paths, non-role email addresses,
tailnet/internal hosts and AWS/Supabase identifiers. Exact reviewed blob SHA256
entries adjudicate identifiers only; the tiny list records checker/test regexes
and any pinned workflow bytes that need review. Trusted policy bytes are likewise
exempt from identifier review only, never from secret scanning.

The public PR guard runs the base commit's script/policy on the exact candidate
head. When the base has no checker, the installation PR runs the candidate checker
in explicitly labelled REPORT ONLY mode; findings do not fail installation and
require coordinator manual review. Local bootstrap preflight still enforces the
candidate checker. Once installed, both CI and `pre-push-public` execute the base's
checker/policy: candidate policy edits cannot loosen their own checks. Repository
rules must protect the workflow itself; settings remain coordinator-owned.

Generic public identifier classes supplement the private exact customer/owner marker,
fingerprint and rights scans. Private marker values/manifests are not published.
Coordinator must still run private stage-1 scans and review public author identities
before each push. This public guard cannot certify every private identifier/rights
issue. Helpers do not install hooks, modify refs or push.

## Local evidence and next gates

- Round 2: 20 contract tests cover ordinary new components
  and tests, role addresses, private paths (including an intermediate deleted file),
  symlinks, submodules, size limits, personal/internal/tailnet identifiers, a fake
  AWS key, secrets despite identifier adjudication, commit metadata, unrelated roots,
  trusted-base policy/checker enforcement, and report-only installation bootstrap.
  Temporary repositories are removed.
- Canonical Python sample: 67 passed, zero failed, one platform skip in
  tests/agent/test_prompt_builder.py. Eight-slice generation exercised locally.
- New Python files: pinned ruff; helper shell syntax and YAML parsed locally.
- Mobile full Swift package: 500 tests, zero failures, local macOS 26 / Swift 6.4.
- No npm tree installed under constrained disk budget. Direct boundary command
  reported missing TypeScript dependency; no source-level conclusion from that run.
- Full Python suite, JS/lint and Linux GUI execution remain exact-head coordinator
  gates. Full Python run not attempted under local disk/time constraints.
- Removed the per-file path manifest; each policy now contains only deny rules,
  public ancestry anchors, the size limit and a tiny identifier adjudication map.

Do not retire duplicate private checks based solely on this checkpoint.

## Mobile detailed resource disposition

| Previous verify.yml job | Public replacement / disposition |
| --- | --- |
| resources: importer and push projection tests | resources + existing client; importer 8 tests and projection 2 tests pass locally; verify/generate-push checks pass. |
| resources: broad unittest discovery | stays private: local public discovery ran 63 tests with 2 failures, 29 errors, 7 skips; excluded probe/study scripts and contract fixtures cause errors. No private inputs copied to make this green. |
| resources: native-catalog / API / turn / auth / deletion / push-localization generators | stays private until input relocation: native-catalog fails on excluded design catalog; full parity not claimed. |
| swift: swift test --package-path ios | swift on standard macos-26, 500 tests passed locally. Package tools-version 5.10; no Xcode project build. Hosted image execution still pending. |
| swift: notification fallback, prototype-session, SDK study | stays private initially: these separate runtime assertions are not replaced by Swift package tests. |
| ios-app client simulator | `app-tests` on standard public `macos-26`; runtime destination discovery avoids coupling the workflow to one preinstalled simulator runtime. |
| sdk-custody, sdk-apple, phone and signing/release | stays private per source/evidence boundary. |

The public Swift test lane is independent of the disabled Xcode-project build.

Identifier adjudication is limited to two exact checker/test blobs containing
public regex and synthetic test source. Role email addresses are allowed as a
class. Workflow action SHAs are ordinary public identifiers, requiring no special
adjudication. No private owner/customer/infrastructure values were introduced.

Final local outbound preflight: PASS for the complete new commit range in both
repositories (raw objects/modes, paths, ancestry, identifiers, pinned gitleaks and
metadata). Stage-1 gitleaks scan over all newly authored bytes: zero findings.
Round 2 guard contract tests: 20 passed in each repository. No remote actions.
Generated Swift build output and checkout-local test/bytecode caches were removed;
no npm tree was installed. Peak combined checkout footprint was below one GiB.

Round 2 local checkpoint (2026-11-10): replaced exact-path approval with deny-only
policy, retained all CI parity lanes, added base-trusted local preflight and
report-only CI installation bootstrap. Full new-commit outbound preflight and
focused guard tests pass on both amended heads. Built locally; no push, PR,
settings changes, CI execution or spending. Coordinator owns publication/review.

## 2026-11-10: UUID node groups are not AWS account ids

The outbound guard's AWS-account pattern (`\b\d{12}\b`) also matched the last group of synthetic
fixture UUIDs whose last group is all digits (the zero-padded test UUIDs), so vendored provider contract packs
(hash-pinned upstream, so not editable here) were refused as "new identifier". The pattern is now
`(?<![0-9a-f]{4}-)\b\d{12}\b`: a bare 12-digit run is still refused, a UUID's final group is not.
Tests `test_allowed_uuid_node_of_digits` and `test_denied_bare_account_id` cover both; the reviewed
blob hashes for the guard and its tests are updated in `scripts/public-boundary.json`. Every other
identifier class, the gitleaks scan and the path policy are unchanged.

## 2026-11-12: reserved example domains are not personal addresses

The wave 3 desktop copy export (atum-desktop `055bd491`) carries a DM identifier placeholder
address (local part `you`, domain `example.com`), so the vendored `Localizable.xcstrings` was refused as "new identifier". Addresses
at RFC 2606 / RFC 6761 reserved names (`example.com`, `example.net`, `example.org`, `*.example`,
`*.test`, `*.invalid`, `*.localhost`) can't route to a person, so the email class now skips them, like
role addresses. A routable lookalike (`example.com.co`) is still refused. `test_denied_personal_email`
now uses a routable domain; `test_allowed_reserved_example_domain` and
`test_denied_lookalike_of_reserved_domain` cover the change. Reviewed blob hashes for the guard and
its tests are updated in `scripts/public-boundary.json`. Every other identifier class, the gitleaks
scan and the path policy are unchanged. Local note: run the guard tests with
`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null` when a global hooks
path blocks commits in the tests' temporary repos.
