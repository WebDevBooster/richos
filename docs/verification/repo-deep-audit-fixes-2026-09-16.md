# Deep-audit repairs and complete recheck, 2026-09-16

The three findings in [the deep audit](repo-deep-audit-2026-09-16.md) were
fixed, merged individually and pushed to `main`. The audit files were committed
and pushed first as `6a242c65`. The historical reproductions remain unchanged.

The broader verification found additional problems in the integrity probe, verification,
adoption and interface paths. Each repair also has its own implementation and merge commit.

| Repair | Implementation | Merge |
| --- | --- | --- |
| Preserve the original partition when correcting a Loro record | `09339f23` | `ba03adb1` |
| Enforce physical Loro storage boundaries | `4d597d48` | `0f6e1aad` |
| Require reliable worker-settlement evidence | `ef688b5d` | `70b5df85` |
| Avoid false missing-unit errors from the engine inventory pipeline | `8cb909c9` | `31e61be9` |
| Restore CEO TODO initialization to bootstrap instructions | `c2d409ee` | `4b0b63e1` |
| Include shipped UI modules and current states in browser gates | `96465ce8` | `3eaca2dc` |
| Measure new UI surfaces and repair their contrast | `f38cc3c1` | `cac72656` |
| Drain integrity-probe selectors and test predicates | `40014a0b`, `6bc4ec94` | `62cc9066` |
| Refresh the workspace mutation target after the key/name refactor | `6511d725` | `f6eaa92e` |
| Refresh its remaining copy in the fourteen-point campaign | `44e1d764` | `71ec86df` |
| Consume complete mechanical-sweep reports before announcing them | `1f0acf37` | `366e5b20` |

## Original findings

A correction now inherits the original record's company, CEO or unfiled lane.
An explicitly different partition is refused instead of silently moving the
record. The desktop integration test exercises the actual CLI writer and checks
that a correction does not enter another company's context.

All Loro output paths now share the physical storage checks. Existing linked
child directories, linked files, dangling links and hard-linked destination
files are refused. External corpus writes cannot enter a product checkout.
Private temporary files are flushed before publication, with exclusive creation
for new records. Both supersession destinations are checked before either write.
The same checks cover company manifests, coverage baselines and citation relinks.
A safe alias of the corpus root remains supported. These checks protect against
pre-existing filesystem redirections; they do not claim to provide an operating
system sandbox against concurrent hostile ancestor replacement.

A native turn cannot end normally when worker evidence is missing, unreadable,
malformed or reports unsettled workers. The owned provider process is stopped
and reconciliation evidence is retained. A shared journal lock coordinates
readers with the hook writer. Lock contention has a bounded wait and remains
unavailable if the writer does not release it. Tests cover an open worker,
a damaged journal, a missing journal, an unreadable journal, an empty valid
journal and a settled worker. Only the last two permit a normal turn end.

The new regression tests were run against the defective implementations before
repair and failed. The before/after records are retained in the sibling evidence
directory. The current permanent regressions can be rerun with:

```sh
python3 docs/verification/repo-deep-audit-fixes-2026-09-16/recheck.py
```

The script uses synthetic data and requires positive Rust test summaries, so a
filter that runs zero tests cannot count as a pass.

## Additional findings during verification

The engine runner piped `cut` into an early-exiting `grep -q` under `pipefail`.
With a large inventory, `cut` could receive SIGPIPE after a successful match and
the runner would falsely call that unit absent. It now reads the inventory with
one `awk` invocation. The runner suite includes a 2,000-unit regression fixture
and passes all 34 checks.

The bootstrap completion checklist required CEO TODOs but no longer told the
interviewer to initialize them. The instructions now name the initializer,
protect existing declarations and require the lint result. All 31 cold-open
checks pass.

The browser inventory omitted `work-summary.js`, `repositories.js` and
`permissions.js`. Nine browser suites initially failed or could not produce
coverage because of the missing entries and related stale state/menu/docs
expectations. The repair declares those product modules, classifies the current
source-derived states, updates the menu order and documents the current test
inventory. Five new live WebKit fixtures exercise empty repository connections,
a pending permission and account start/poll/cancel errors. Existing assertion
thresholds and negative controls remain in force.

The expanded contrast walk now covers 31 surfaces in both themes. It exposed
a low-contrast disabled repository button and saved-work scrim. The button now
uses readable neutral colors and the nonmodal sidepane dismissal target no
longer dims the content underneath it. The shared node count was remeasured
across the full walk. WCAG thresholds and the three-node tolerance remain
unchanged; no new surface exemptions were added.

The integrity probe and several test assertions also used early-exiting
`grep -q` pipelines. A successful match could produce SIGPIPE in the writer and
be reported as a missing remedy or failed assertion. First-match `awk` selectors
could also terminate the probe itself with exit 141. Predicates and selectors
now consume the complete input. A large-refusal regression checks that the
remedy is recognized and a negative control checks that an absent remedy still
fails. A large hook-inventory regression checks both a valid configuration and
a missing guard, requiring the expected diagnostic instead of a broken pipe.

Two workspace mutation campaigns still targeted the old name-only condition
after the implementation began accepting both workspace names and stable keys.
The second copy was found when the longer campaign finished after the first
repair had already landed, so it has a separate follow-up commit and merge.
Both targets now match the current condition. They still remove the same
new-work block and must be caught by their existing behavioral tests.

The mechanical-sweep hook had a related production failure: its report parser
used `head -1` under `pipefail`, so a large valid report could terminate the hook
with exit 141 before it wrote its receipt or notification. The parser and its
first-refusal selector now consume the complete input. A real 405-finding
fixture reproduces the failure before repair and checks both the initial notice
and the following silent, fully recorded sweep after repair. All 46 checks also
passed in 20 complete repeated runs, four at a time. The MF mutation campaign
and the standalone suite both passed.

## Final verification

Final code revision: `366e5b20470b4b21384b7247a00eb54f551ee748`.

The native crates, Tauri implementation, service and extension were fully tested
at `70b5df85`; their source trees are identical at the final code revision. The
full browser and packaging runs passed at `cac72656`. The engine asset checks
also passed with the subsequent integrity-probe repair at `40014a0b`; the final
sweep repair is checked separately at `1f0acf37`.

The complete engine inventory was exercised at `3eaca2dc`. Its failures led to
the final probe/assertion and mutation-target repairs. The affected suites were
then rerun completely. The workspace suite ran with the exact patch subsequently
committed as `6511d725`; all 24 integrity sections ran at `6bc4ec94` and the
fourteen-point campaign passed at `44e1d764`. The integrity run passed 23
sections and exposed the independent mechanical-sweep failure in MF. Its
canonical receipt verifier correctly refused to certify that run. The complete
MF mutation campaign and standalone mechanical suite were then rerun at
`1f0acf37`. Raw receipts retain their original revisions and
failures. The coverage ledger reconciles all discovered units with their repair
reruns; it is explicitly not a single-revision CI coverage certificate.

Engine tests run in complete disposable checkouts with Docker `--init`; the
Docker-dependent container-cleanup unit runs on the macOS host. The user's
other worktrees are not used as test fixtures.

| Check | Result |
| --- | --- |
| Rust workspace, including integration and doc tests | 1,256 passed, 8 ignored |
| Tauri shell | 98 passed |
| User updater | 37 unit tests and 1 integration test passed |
| macOS companion | 41 passed |
| Windows companion core | 26 passed |
| Windows companion Release build | Passed |
| Service and Workspace | 365 and 91 passed |
| Extension | 66 passed |
| Service mutation audit | 41/41 detected |
| Five service E2E suites | All passed with named optional skips |
| Engine non-suite verification | All 6 steps passed on the combined tree |
| Earlier audit reproductions | Repaired behavior retained |
| Three new audit regression groups | Loro 207 checks, 13 boundary checks and relocation; desktop 4; settlement 1 with 6 scenarios; evidence lock 2 |
| Full browser inventory | 35 suites, 572 checks passed, 0 skipped |
| Full engine inventory | 147/147 units covered by the full inventory and repair reruns |
| macOS packaging inventory | 9 suites, 180 checks passed |
| Tracked-file syntax | 414 Python, 500 shell, 171 JS and 55 MJS files passed |

One Docker-dependent retry shared a disposable checkout with browser screenshot
generation. Its canary correctly rejected the changed tracked PNGs. Another
retry was launched with the wrong working directory and caught edits to the
report in the main checkout. Both receipts remain failures. The final retry
used a dedicated checkout as both its source and working directory and passed
all assertions and the real-checkout canary.

The initial packaging run correctly refused a reused runtime whose Python cache
files no longer matched its delivery manifest. A fresh extraction from the
existing engine archive passed the full runtime verification against the tracked
public-source recipe. The packaging retry uses that verified extraction with
Python bytecode writes disabled. The runtime inventory was not rewritten and no
validation was bypassed.

[The coverage ledger](repo-deep-audit-fixes-2026-09-16/engine-coverage.json),
[source identities](repo-deep-audit-fixes-2026-09-16/source-identities-final.json)
and [check records](repo-deep-audit-fixes-2026-09-16/checks.json) record the exact
verification scope.

Initial failures and interrupted engine attempts are retained separately from
final receipts. An interrupted mutation campaign is not counted as completed
coverage. No remote CI workflow was enabled or dispatched.

## Limits and remaining follow-up

The existing moderate Linux `glib` dependency advisory remains open. This task
did not change dependencies or dismiss the alert; the earlier
[dependency analysis](repo-audit-post-refactors-fixes-2026-09-16.md#open-dependency-advisory)
explains why a lockfile-only version bump is insufficient.

No live Windows capture, live provider authorization, paid doctrine-sentinel
turn, microphone/output-device checks, personal corpus test or nightly
installation was performed. The E2E suites retain their named optional-memory,
Windows-surface and large-v3-model skips. The GUI boot suite also declares its
existing vocabulary-service installation gap. Local regression coverage does
not establish that those external integrations work.

Raw logs and disposable checkouts are retained at
`/Users/alex/ab/richos-rechecks/deep-20260916`. Existing untracked `.DS_Store`
files and the nightly/voice worktrees were left untouched.
