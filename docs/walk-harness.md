# Reusable VM walk harness

The harness separates operation timing from scenario coverage. A fast run with a
missing prerequisite is not a passing walk. The offline suites exercise the command
boundaries. Acceptance also requires a live guest: successful webview and Safari
focus/type, key reuse after idle/relaunch, real signed update/rollback and the full
scenario. Keep those measurements in a private handoff with the raw evidence.

## Bounded accessibility operations

From `richos/app/scripts/testvm`:

```sh
./ax.sh VM find --title Settings --in sidebar --first
./ax.sh VM focus --role AXTextArea --in composer --first
./ax.sh VM type 'fixture text' --role AXTextArea --in composer --first --replace
./ax.sh VM type 'fixture text' --app Safari --role AXTextArea --first --replace
./ax.sh VM click --title Close --in dialog
./ax.sh VM find --role AXButton --in window 'RichOS' --nth 1 --json
```

Matching reads only the requested attributes. Returned nodes carry full attributes
and geometry. Traversal is breadth first. `--first` stops at the first match and
`--nth N` at the zero-based Nth match in that traversal order. These flags deliberately
do not establish uniqueness. Without either flag, `find` is exhaustive and actions
require exactly one match. A node or depth cap is an incomplete result and fails.

Scopes select the first matching dialog, sidebar or composer subtree. `--in window`
selects windows by exact title. An absent scope fails. A composer is its form group,
with a text area's parent as a fallback. `focus` verifies focus before returning;
`type` verifies focus before sending and checks the resulting value. The text may
contain newlines; no Send/Return is issued automatically. A coordinate click uses
AppleScript and requires the intended process to be frontmost.

The default 20-second deadline includes host preflight, SSH, guest execution and
rendering. The guest gets a shorter allowance for diagnostics and cleanup. Timeouts
return 124 with partial output preserved; the owned command group is killed.
`SecurityAgent` windows produce `blocked`, distinct from `notfound`. Process errors
retain their exit status. `TESTVM_AX_TIMEOUT` can select a different total bound for
a controlled comparison, but increasing it is not a recovery strategy.

## Fixtures and exclusive execution

Use synthetic fixture homes. `fixture.py --source HOME --out NEW_HOME --kind delta`
keeps two bound thread definitions named `Scenario A` and `Scenario B`, removes old
turns, drafts and runtime journals, and retains entity/configuration data. The
`long-history` kind preserves the conversation history for a separate AX benchmark.
Both exclude copied keys, Claude credentials and installed update state. Inputs stay
unchanged; unexpected symbolic links are refused. The output `fixture.json` records
the source and resulting ledger hashes. The caller owns deletion of these copies.

`run-walk.py` holds the same `<state-dir>/release.lock` as `nightly-local.py`. Its
default state directory is `~/.richos-nightly`; `--state-dir` must match the nightly
when overridden. Acquisition is nonblocking and host load must be below 8. Under
that lock it refuses another running clone, creates a unique headless guest and
keeps the reservation until `stop.sh` has stopped the captured processes and deleted
the clone. It also cleans up after boot failure or interruption. Only `caffeinate -is`
is used by the underlying VM launcher.

Example, with paths and pinned versions supplied by the operator:

```sh
cd richos/app/scripts/testvm
./run-walk.py --bundle "$CURRENT_ZIP" --home "$DELTA_HOME" --engine "$ENGINE_TAR" \
  --previous-bundle "$PREVIOUS_ZIP" --report "$RESULTS/run.json" -- \
  ./delta-walk.py --out "$RESULTS/delta" \
  --previous "$PREVIOUS_VERSION" --current "$CURRENT_VERSION" \
  --endpoint "$PINNED_CURRENT_MANIFEST" \
  --band-box "$X0" "$Y0" "$X1" "$Y1" --band-color "$BORDER_COLOR" \
  --chip-box "$X" "$Y" "$WIDTH" "$HEIGHT"
```

The runner inserts its VM name immediately after the scenario executable. The
previous bundle is staged into that guest and passed as `--previous-app`. The
manifest URL must include `/releases/download/v<CURRENT_VERSION>/`. Version
arguments themselves omit the `v` prefix. The previous app's bundle version is
checked before it is installed in the disposable guest's user Applications folder.
Only the real updater creates receipts. `rollback.py --check-only` validates an
existing history before any UI exploration; missing history is a prerequisite
failure. The scenario takes the signed update, activates it, reads the updater's
receipts, rolls back, then checks both boot identities and the new update offer.

Place results, fixture copies and the configured `TMPDIR` on the designated scratch
volume. Keep result files outside disposable fixture directories. Reports and OCR
caches can contain fixture text and paths; do not publish them without the privacy
gate. After inspection, delete the caller-owned scratch and caches.

## Scenario evidence and limits

`scenarios/delta.json` specifies order, dependencies, limits and outcomes. Five Mac
turns supply typed-to-phone and first-word samples. One phone turn supplies
phone-to-Mac and the thread-switch capture. Send attempts count before sending;
there is no automatic retry and recovery cannot exceed six total attempts. A missing
reply is a measured failure, not a reason to keep sending diagnostic prompts.

Each prompt contains spaced characters; the requested reply joins them. Thus the
reply token is absent from the prompt. Desktop and phone OCR streams stay separate.
Offsets use the capture's millisecond timestamps, including its action window. The
reply-to-phone result is a signed difference because capture cadence can place the
phone observation before the Mac observation. Keep the frame cadence and action
window alongside the result when interpreting subsecond numbers.

Captures use fixed desktop and Safari rectangles. Check the supplied band boundary
and chip rectangles against a guest frame before acceptance. Band coordinates are
relative to the phone crop by default (`--band-side mac` changes this); chip
coordinates are relative to the desktop crop. The band check examines every
band-visible frame and requires an actual boundary color measurement. The old detail
line is searched across both complete frame streams. A switch at eight seconds only
qualifies if work is visible immediately before it; otherwise the chip check reports
`prerequisite unavailable`. AX must also confirm that the destination is selected.
These checks fail closed if a changed layout no longer exposes the expected evidence.

The rejection check runs before rollback. It verifies the stored rejection survives
relaunch, the rejection explanation is visible and the app has no listener on 8443.
An expired pairing URL alone is insufficient evidence.

Every step reports `PASS`, `product failure`, `harness failure` or
`prerequisite unavailable`, elapsed time and evidence or a failure reason. Failed
dependencies name the skipped work; independent steps continue. `report.json` gives
scenario coverage and model attempts. The outer `run.json` separately records boot,
scenario, cleanup and complete elapsed time. Use the inner report for classifications;
a nonzero scenario exit alone cannot distinguish a defect from a missing prerequisite.

## Keychain endurance outside routine timing

`keychain.sh prepare` configures and reads back the GUI session's default/search list,
unlock state and no-timeout settings. Its prerequisite probe uses the default search
list with normal access controls. It does not use `-A` or broaden actual app-key ACLs.

Add `--keychain-endurance` to the delta command for a separate zero-model-turn run:
initial pairing, over 30 minutes idle, relaunch and existing-key reuse. Alternatively,
run `keychain-verify.py VM --output REPORT` against an already paired owned guest
inside the reservation. `--idle-seconds` must exceed 300; the default is 1801.
It fingerprints the app's three actual accounts under the service derived from its
guest data directory. Secrets never leave the guest. A listening channel after
relaunch and unchanged keys provide the reuse evidence. SecurityAgent is sampled
every 15 seconds and at access boundaries; this cannot prove that a shorter transient
prompt never existed. Preserve guest capture/log evidence for that stronger claim.
A remaining prompt or timeout fails the prerequisite and may require a product fix.

## OCR reuse and comparisons

Set `RICHOS_QA_OCR_CACHE` to a private per-walk cache directory. `ocr-find.sh` accepts
repeated `--pattern`, `--timeline`, `--json` and `--flat` flags. With several patterns,
`--first` means the first hit of each pattern and exit 0 requires all patterns.
Exit 1 means an absent pattern; exit 2 means analysis could not run. Omit `--first`
for an absence claim that needs every frame.

Cache identity includes image bytes, reader bytes/version, options, locale and OCR
configuration file contents. Successful empty reads are cached; failures are not.
`ocr-gate.sh` uses cached text but evaluates current privacy rules every time. Its
positive control always invokes the reader again. No cached clean verdict exists.

For an AX speed comparison, use the same long-history fixture hash, guest resources,
product build and starting UI state for baseline and candidate. Time each known
lookup/focus/type/click separately and verify its effect, including the app and
Safari fields. Record absent and modal cases separately. For OCR, run the two queries
on identical immutable frames with identical reader/configuration settings; record
cold and warm times and verify identical hits. Do analysis after timing captures.
Report complete scenario duration with coverage separately from these operation
comparisons. An unfinished historical run is not an equivalent speed benchmark.
