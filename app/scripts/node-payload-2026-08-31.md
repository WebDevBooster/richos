# What the Node/ACP side of RichOS would have added to a customer's download

> **Path note (2026-09-01).** measure-node-payload.sh, then at app/scripts, was removed in b42dc70; the adapter it measured — app/acp-adapter/ — was deleted in a45acc3. Filenames below are therefore given bare: they resolve in git history at those commits, not in the current tree.

**SUPERSEDED 2026-08-31, and kept because its measurements are still the only ones anybody
has taken.** This was `measure-node-payload.sh`, a script that installed
`app/acp-adapter/node_modules` from the lockfile and measured it. `wiki/ceo-decisions.md`
§16 deleted that directory, so the script can no longer measure anything and was removed
rather than left to exit 1 or, worse, to print a pleasingly small number for a tree that
was not there.

**Every figure below was MEASURED on this Mac on 2026-08-31, before the deletion.** They
are retained verbatim because `open-items.md` **3.14** — the payload-placement question —
now has to be re-put on the new build, and re-putting it needs the old numbers to say what
changed. Three of the findings at the bottom are not sizes at all and outlive the adapter
entirely.

**What is now WRONG about them, stated first so nobody quotes them as current:** options A
and B below cost a bundled Node runtime and a bundled npm tree that RichOS no longer has.
The build this repository produces today is option C's shape with none of C's prerequisite
— no Node, no adapter, no npm — and the only remaining question is the one 3.14 asks: does
RichOS ship the `claude` binary itself, or require the customer to have Claude Code?

---

## The run of 2026-08-31

Against the adapter's `package-lock.json` as locked
(`@agentclientprotocol/claude-agent-acp` 0.70.0 → `@anthropic-ai/claude-agent-sdk` 0.3.232).
All figures measured unless labelled.

| | bytes | MiB |
|---|---:|---:|
| `node_modules`, installed from the lock | 340,445,066 | 324.7 |
| …of which the native `claude` binary | 306,111,312 | 291.9 |
| …of which everything else (JS, types, maps) | 34,333,170 | 32.7 |
| …minus declarations, maps and docs | 15,481,673 | 14.8 |
| …minus those AND vendored test/doc dirs | 14,513,215 | 13.8 |
| node v22.20.0 darwin-arm64, official build | 111,332,720 | 106.2 |
| …`strip -x`ped and re-signed | 89,488,384 | 85.3 |

The two prunings differ because they are two methods, and both were reported rather than
one being picked: the script subtracted by file extension, which is what a script can do to
a tree it must not modify; the 14,513,215 figure is a tree that was actually built, had its
vendored `test/` and `docs/` directories removed too, and was then RUN. Use the larger for
a promise and the smaller for a ceiling.

## The three placements, assembled into real bundles and RUN

Totals INCLUDE RichOS.app itself at 13,422,371 B.

| | | gzipped |
|---|---:|---:|
| **A** bundle node + adapter + the Claude binary | 403.9 MiB | 122.0 MiB |
| **B** bundle node + adapter, customer's own Claude | 112.0 MiB | 40.3 MiB |
| **C** bundle neither; Node and the adapter are a prerequisite | 12.8 MiB | 5.6 MiB |

The Node side was not a component of the download in A and B; it WAS the download.
Whisper's 4 MB, and the 20 MB of screenshots removed from the binary the same day, are both
rounding errors against it.

## Three findings that are not sizes, and two of them still apply

1. **The Claude binary is per-architecture.** `darwin-arm64` and `darwin-x64` are separate
   packages. A universal build carries both or ships two DMGs. **STILL APPLIES** to 3.14's
   "ship the binary" branch.
2. **`strip` KILLS a macOS arm64 binary.** The stripped node exited 137 (SIGKILL) until it
   was re-signed: modifying the file invalidates its code signature and the kernel refuses
   it. Any trimming step must be followed by a re-sign — which the app's own codesign pass
   does anyway, but only if the trimming happens BEFORE it. **STILL APPLIES** to anything
   RichOS trims or fetches.
3. **Option B's failure mode was clean.** With no native package and no
   `CLAUDE_CODE_EXECUTABLE`, the adapter threw *"Claude native binary not found for
   darwin-arm64"* rather than hanging or half-working. **NO LONGER APPLIES** — there is no
   adapter. The equivalent on the native path is `NativeError::BinaryMissing` /
   `NativeError::Startup` from `native.rs`, raised before any turn and carrying the child's
   own stderr.
