# Repository audit, 2026-09-16

**Resolved:** all five findings below have been fixed. See the
[fixes and complete recheck](repo-audit-fixes-2026-09-16.md), including three
additional path cases found during the second review. The remainder
of this document records the original audit.

Audited revision: `221f3d80`. Reviewed the product relocation (`59b492c3`),
Mega Lander extraction (`37acdbd9`), PreToolUse dispatcher refactor
(`5e3ea207` and follow-ups) and the fixes from the September 15 audit.

Five newly reported findings remain: three privacy-boundary gaps, one
installer defect and one dispatcher reporting regression. The existing
Windows storage issue also remains. No product code was changed.

P1 means high priority; P2 means normal priority. The privacy findings concern
local writes into a publicly shipped source checkout. No upload or actual
disclosure was performed or observed.

## 1. P1: Corpus provisioning follows a symlink into the product checkout

Source: [provision.rs](../../richos/app/crates/richos-core/src/provision.rs),
lines 169-194; called before provisioning at line 395.

`product_checkout_containing` walks the supplied path's lexical ancestors.
Filesystem marker checks follow symlinks, but walking to the parent of an
alias does not walk to the parent of its destination. An alias to a directory
*within* the checkout therefore hides the enclosing product markers.

**Executed reproduction:** Create a synthetic grouped checkout containing
`richos/app/crates/richos-core/Cargo.toml`. Create an external symlink pointing
to that checkout's `docs` directory. Request a new corpus below the symlink.
Call the real Rust `provision` function with no home pointer or companies.

```text
physical path refused: true
symlink path refused: false
provision accepted: true
private directory created inside product: true
```

The real provisioner creates the corpus inside the synthetic product tree.
Subsequent memory writes can therefore land in the checkout that this check
explicitly promises to exclude. The passing grouped-layout test only covers
direct paths.

**Fix:** Resolve the nearest existing ancestor before locating the enclosing
checkout, retaining missing suffix components. Refuse unresolved links and
test both an alias into a checkout and an alias to legitimate external storage.
Preserve the caller's chosen display path if needed.

This gap predates the relocation. The historical symlink-related revert
`d5f12a94` concerns the name displayed for an existing corpus pointer. It does
not address or authorize provisioning inside the product checkout.

## 2. P1: The macOS recorder still accepts symlinked recording paths into the checkout

Source: [DropZone.swift](../../richos/tools/richos-service/companion-macos/Sources/RichOSCompanionCore/DropZone.swift),
lines 102-115.

The recorder's `isInside` check uses `NSString.standardizingPath` followed by
a string-prefix comparison. An external symlink to the checkout's `docs`
directory passes. Yesterday's Node service fix resolves filesystem ancestors,
but the Swift implementation that claims to mirror it does not.

**Executed reproduction:** Compile the actual `DropZone.swift` with a small
driver, create a disposable checkout directory and an external alias to its
`docs` directory, then call `DropZone.resolve` for a recording directory below
the alias while supplying the correct product root.

```text
physical path refused: true
symlink path refused: false
recorder accepted zone: <sandbox>/swift-fixture/external-link/recordings
```

This accepts a recording destination inside the product checkout. The Node
service now rejects the same physical destination, so recording and
transcription disagree about a permitted location. No audio was recorded in
the reproduction.

**Fix:** Apply physical containment checks in Swift before capture starts,
including missing final directories and unresolved links. Test the recorder's
public resolver against the same path cases as the service.

This is pre-existing, not introduced by the directory move.

## 3. P1: An explicit service session path bypasses the private-storage check

Source: [richos-service.js](../../richos/tools/richos-service/bin/richos-service.js),
lines 72-75 and 102-115.
Writer: [pipeline.js](../../richos/tools/richos-service/lib/pipeline.js),
`runPipeline`, starting at line 97.

The CLI validates the configured drop zone, then `resolveSessionDir` accepts
an independent absolute or relative session path without validating it. Both
`run` and `retranscribe` pass that path to the pipeline, whose output directory
is the session directory itself. Validating an unused zone does not validate
the actual destination.

**Executed reproduction:** Copy the real service and its extension dependency
into a disposable grouped product tree. Put a synthetic `session.json` in
that tree's `docs/session`. Configure an external drop zone. Invoke the actual
CLI with `run <absolute-product-path>/docs/session --model small.en`.

```text
same_destination_as_zone_refused: true
explicit_session_exit: 2
explicit_session_privacy_refusal: false
pipeline_wrote_inside_product: true
```

The exit 2 is the expected no-audio anomaly, not a privacy refusal. The pipeline
rewrites `session.json` inside the protected tree. The same destination passed
as `--zone` is refused before processing. The synthetic case proves entry into
the writer; the later normalization and transcription stages likewise write
their audio derivatives, transcript and verification into `sessionDir`.

**Fix:** Validate the resolved session destination before any pipeline write.
Put the invariant at the writer boundary or ensure every caller applies it.
Allow legitimate external session directories even when they are outside the
configured drop zone. Test both CLI commands and symlinked session paths.

This is pre-existing and remains after the service's symlink fix.

## 4. P2: Reinstalling the browser bridge retains stale installation paths

Source: [install-host.sh](../../richos/tools/richos-service/host/install-host.sh),
lines 23-32.

The installer uses `richos-host-launcher.sh` as both its input template and
output. The first installation replaces the `__NODE_BIN__` and `__HOST_JS__`
tokens. Later installations have no tokens left to replace, so they retain
the original paths even when the checkout or Node executable has moved.

**Executed reproduction:** Copy the host into a temporary old location,
install it under a fake browser home, move the directory and rerun the real
installer. Both installations return 0. The manifest points at the new
launcher, but that launcher still names the old `native-host.js`. Executing
it returns 1 with `Cannot find module` for the old location.

**Fix:** Keep a separate immutable template or generate the launcher from the
newly resolved values on every installation. Add a reinstall-after-move test
and a test that changes the resolved Node path.

The installer defect is pre-existing. The directory relocation makes it
relevant to existing installations; a fresh checkout with intact template
tokens does not exhibit it on the first install.

## 5. P2: Dispatcher failures become successful hooks with hidden diagnostics

Source: [dispatch-pretooluse.sh](../../richos/engine/scripts/hooks/dispatch-pretooluse.sh),
lines 294-310 and 321-326.

An absent module, missing process status or module exit other than 0/2 is
reported only on stderr. None changes the aggregate exit status from 0.
Unless another module blocks or emits stdout, the dispatcher therefore
returns a successful hook with no visible output despite unevaluated rules.

**Executed reproduction:** Run the real dispatcher and root-resolution
libraries in a disposable engine with a manifest naming one absent module
and one module that exits 1:

```text
exit: 0
stdout: ''
stderr: ERROR: ... missing-rule.sh ... NOT PRESENT ...
        ERROR: ... broken-rule.sh ... exited 1 ...
```

The dispatcher itself documents that stderr at exit 0 is hidden on
PreToolUse. That behavior was also measured in the repository's
[channel investigation](escalations/2026-09-14-zach-opus-b1-layer-r-governs-53-of-the-60-hooks-that-carry-the-bootstrap-.md).
The current dispatcher tests assert diagnostic text on stderr but do not
assert delivery through a visible channel. This audit reproduced the process
output; it did not start a fresh live Claude session to repeat the host-channel
measurement.

**Fix:** Preserve the intended nonblocking policy while delivering these
failures in a valid visible hook envelope, merging with any module output.
Test the final exit status and stdout envelope for absent, crashed and
unstarted modules. An aggregate error must not disappear when another module
also emits a notice.

This reporting regression belongs to the dispatcher refactor, unlike the
four pre-existing findings above.

## Reproduction evidence

[reproduce.py](repo-audit-2026-09-16/reproduce.py) exercises all five findings
against the actual source using disposable fixtures.
[results.json](repo-audit-2026-09-16/results.json) records its output at the
audited revision. Run with Python 3 on macOS with Node, Rust and Swift available.
Rust dependencies must already be cached because the probe uses offline mode.
The fixtures contain no real recordings, credentials or browser configuration.

## Verification

- Rust core and voice workspace: 1,212 passed including documentation tests;
  eight ignored.
- Tauri desktop: 98 passed using the separate audit Cargo target directory.
- Detached user updater: 38 passed. Its tests also execute a filtered child
  test; that child invocation is not counted a second time here.
- macOS capture companion: 37 passed.
- Node service: 332 passed. Workspace integration layer: 72 passed.
- Browser extension: 66 passed.
- Packaging: all nine suites passed, 178 checks.
- Engine: 20 selected suites passed covering relocation, workspaces, spawn,
  completion proofs, root resolution, isolation, removal, registration,
  dispatch, dependency discovery, census and installer state isolation.
  These used `RICHOS_MUTATION_INNER=1`; no complete mutation campaign is claimed.
- All 494 tracked shell files passed `bash -n`; all 378 tracked Python files
  parsed before adding the audit reproduction script.
- All 150 tracked JavaScript files under `richos` passed `node --check`.
- The actual publication-completeness gate passed.
- The installed engine pointer and `locate-engine.sh` both resolve to the new
  grouped engine location.
- Browser UI: all 31 suites passed, 554 checks and zero skips. All 24 tracked
  screenshots regenerated during the run were restored to their original bytes.

Detailed local suite logs are under `/tmp/richos-audit-*-0916.log` and
`/tmp/richos-audit-engine-0916/`. The existing
`hook-registration-completeness.test.sh` passed all 35 checks, including the
commit-guard cases.

## Existing issue and limits

The [Windows companion's documented storage defect](../../richos/tools/richos-service/companion-windows/README.md)
remains: its default can put recordings under the current checkout. It is
already reported in the September 15 audit and is not counted as new here.

This was a source and local-behavior audit, not a proof that every repository
path is correct. It did not repeat the multi-hour 141-unit engine campaign,
run Windows or Linux binaries, connect live accounts, record real audio or
publish a signed release. The intentional CI pause was left alone. Ignored
tests and platform gaps are not passes.
