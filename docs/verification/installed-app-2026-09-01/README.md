# RichOS, installed on the CEO's Mac and talked to — measured 2026-09-01

Machine: macOS 15.6, Apple M4. Everything below is a reading taken from a running process
or from a signed artifact on disk. Nothing is inferred from an exit code.

**Install path: `/Users/alex/Applications/RichOS.app`** — his own Applications folder,
outside every checkout, so no resolution can fall back on being run from a repository.

Two bundles were built and installed in sequence, and the second exists because the first
one, working, exposed a defect the first one could not have shown any other way:

| | build 1 | build 2 (installed now) |
|---|---|---|
| source | `7738675` (main) | + the three commits on `echo-opus-in1` |
| cdhash | `c22947efab845e8cd992840dcd92a2ce16c64a86` | `f605657de9199765063c03881952bbd7a471b6e6` |
| signing identity | `Developer ID Application: Alex Booster (TZ33A4QCZJ)`, SHA-1 `BF4D68E6F858688FDAD63148BD271FCA2D02474F` | the same |
| hardened runtime | on (`flags=0x10000(runtime)`) | on |
| secure timestamp | 1 Sep 2026 15:04:44 | 1 Sep 2026 15:11 |
| notarized | **no** — there are no notary credentials on this machine | **no** |

Both report `valid on disk` and `satisfies its Designated Requirement` after being copied to
`~/Applications` with `ditto`, and neither carries a quarantine attribute (`xattr` is empty),
which is why an un-notarized bundle still opens by double-click: Gatekeeper's block applies
to a **downloaded** copy, and this one was never downloaded.

## The designated requirement — the thing his grants are stored against

Byte-identical on both builds, and it names an identifier and a team, not a hash:

```
designated => identifier "com.richos.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = TZ33A4QCZJ
```

The two cdhashes above differ, the requirement does not, and there is no `cdhash` term in
it. That is `rebuild-survival-2026-09-01.md`'s result reproduced by two more builds on the
way to this one: his microphone and accessibility grants survive a rebuild.

## 1. `/usr/bin/open` FORWARDS THE CALLER'S ENVIRONMENT — read this before the boot logs

Every RichOS boot log in this repository, including the ones in
`entity-choice-2026-09-01/raw/`, was taken with `/usr/bin/open` run from a developer shell,
under a sentence that says it hands the process "launchd's environment, none of the calling
shell's". **That sentence is wrong on this version of macOS.** `ps eww` against the running
process, launched exactly that way:

```
PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/Users/alex/.local/bin:/usr/local/bin:...
HOME=/Users/alex
TERM_PROGRAM=Apple_Terminal
CLAUDECODE=1
```

A Terminal's `PATH`, and the calling agent's own variables, inside a supposedly
Finder-equivalent launch. The working directory IS `/` — that part was always true, and it
is what the engine and entity defects turned on — but anything resolved through `PATH` was
being resolved through a developer's `PATH`, and a real double-click has
`/usr/bin:/bin:/usr/sbin:/sbin` and nothing else.

`scripts/launchd-env.sh` strips the caller down to launchd's own set before calling `open`,
and `scripts/launch-launchd.sh` is the launch that uses it. `raw/boot-3-launchd-environment.log`
is the result, and it reads back the environment the process actually received rather than
asserting it:

```
--- the environment the process actually received ---
HOME=/Users/alex
PATH=/usr/bin:/bin:/usr/sbin:/sbin
USER=alex
```

**Two of this build's resolutions only survive because of that PATH, and neither would have
been tested without this correction:** `node` is at `/opt/homebrew/bin/node`, and `claude` is
at `/Users/alex/.local/bin/claude`. Neither directory is on launchd's `PATH`. Both are found
by an explicit candidate list — `resolve_node_bin` (new on this branch) and
`resolve_claude_bin` — rather than by a search that would have come up empty.

## 2. The boot line, from a faithful double-click

`raw/boot-3-launchd-environment.log`, the bundle installed right now, launchd's environment,
working directory read back with `lsof -d cwd` (`n/`), with no company chosen:

```
[richos] launch: fresh (1 window(s))
[richos] entity not resolved from /: unknown root /: no registered entity owns this path — refusing to guess
[richos] no company resolved — RichOS will ask in the window and remember the answer.
[richos] operator: RICHOS_ENTITY (one of femcboost, deeply, prospects, richos, gpt-exporter, webinar-booster) still overrides, as does launching from that entity's repository root.
[richos] loro Tier C: compiling from /Users/alex/Library/Application Support/RichOS/loro-root (via the loro-root pointer in Application Support), node /opt/homebrew/bin/node
[richos] engine directory: /Users/alex/.claude/richos-engine (via engine install pointer)
[richos] compute lease attached over /Users/alex/.local/bin/claude
[richos] no RICHOS_SERVICE_BIN — spoken corrections will be recorded and asked, and confirming one will report that there is no vocabulary to write to
```

No `NO COMPUTE LEASE`. No claim about a missing `claude` binary. The engine resolves through
the install pointer, which is the candidate a GUI launch was given in `engine.rs` for exactly
this case, and the corpus resolves through the pointer this branch added.

`raw/boot-2-after.log` is the same build under the developer-shell `open`, kept for
comparison. `raw/boot-1-before.log` is the build BEFORE the corpus fix, and its fifth line is
the whole defect:

```
[richos] loro Tier C: no corpus configured — re-primes carry no company memory
```

## 3. He is asked which company, and answering it works

`raw/gui-turn-1.txt` is the whole drive, read back from the running window through the macOS
accessibility API — no human hand, and nothing reconstructed for the note. With nothing
saved, the window showed:

```
Which company is this copy of Rich for?
I'll keep everything you tell me under the company you pick, and I'll remember it — you
won't be asked again. You can change it later in Settings.
```

…over all six companies with their thread counts. Clicking `RichOS 1 thread` wrote
`"entity": "richos"` into `config.json`, the picker closed, and the rail rendered the six
entity areas.

## 4. A real turn, through the real `claude` binary

Typed into the composer, Return pressed:

> In one sentence: are you there, and which company are you filing this under?

Rich answered, verbatim, on screen and in the ledger:

> Yes, I'm here — this thread is filed under the richos entity area, and I'm not going to
> guess a finer-grained company than that; tell me which of the six it belongs to, or I can
> check the registry.

Prompt received `1788271637872`, turn completed `1788271643740` — **5,868 ms** end to end,
through session `cddb6276-b6bd-4941-9373-10c70aa6e407`.

**And that turn is where the defect was.** Its re-prime recorded `priming_chars=2562`, and
the boot line above it read `[richos] loro Tier C: no corpus configured — re-primes carry no
company memory`. The app worked; the Rich inside it had no company memory at all, because
`CliContextCompiler::from_env` reads three environment variables and a Finder launch has
none of them. Fixed on this branch; the commit message on `c179cc1` carries the reasoning.

## 5. The company memory, and the first send, under a faithful launch

`raw/loro-under-gui-condition.txt` — `loro_reprime_demo`, which now runs the app's own
resolver, under `env -i HOME=/Users/alex PATH=/usr/bin:/bin:/usr/sbin:/sbin` with cwd `/`,
which is what LaunchServices supplies:

```
[demo] corpus root: /Users/alex/Library/Application Support/RichOS/loro-root (via the loro-root pointer in Application Support)
[demo] node: /opt/homebrew/bin/node
[demo] corpus partitions: deeply, femcboost, gpt-exporter, prospects, richos, webinar-booster
[demo] entity->lane map after reconciliation: 6 entr(ies)
```

The re-prime payload is **3,331 chars / 3,388 bytes**, of which the compiled loro slice is
**1,227 chars / 1,270 bytes**, headed
`COMPANY MEMORY (loro) — bearing on: "the RichOS desktop app"`. All six lanes survive
reconciliation, which is the first time that has been true — his corpus was partitioned
earlier today, and before that a filled-in lane map would have made every re-prime
`Unavailable`.

The slice's CONTENT is his own record and is written nowhere in this repository.

**And the whole first-send sequence, under the launchd-like environment of §1**
(`raw/first-send-launchd-environment.txt`, `scripts/roundtrip-launchd.sh`). Throwaway config
and ledger under `TMPDIR`; a real `claude` lease; the CEO's own state untouched:

```
1. fresh install: no company chosen, no thread active
2. send refused, as it must be: no active thread, and no entity was named — Rich will not
   guess which entity area this belongs to.
3. answered: richos written to .../richos-company-roundtrip-90688-....json
4. next boot reads it back: richos
5. active: ceo-default+richos+thr_1df610064e394521bc0b7f01ab23ab36+r3+-
5b. company memory: .../RichOS/loro-root (via the loro-root pointer in Application Support),
    node /opt/homebrew/bin/node

CEO> In one sentence: are you there?

Rich> Yes — I'm here and ready to pick up wherever you want to go.

[roundtrip] turn state = Completed, stop = Some("end_turn")
[roundtrip] priming_chars=3352
```

The control — the identical run with a `HOME` that has no pointer — records
`priming_chars=2472`. Same code, same topic, same lane; the only difference is whether the
pointer resolves, so **the compiled slice is 880 chars, by difference against a control**
rather than by a number this file kept for itself.

## 6. THE OPERATOR STEP THIS DEPENDS ON, stated because it is not in the app

The pointer is not created by anything. It was created here, by hand, and a fresh machine
will not have one:

```
~/Library/Application Support/RichOS/loro-root -> /Users/alex/ab/richos-hq
```

`ln -sfn /Users/alex/ab/richos-hq "$HOME/Library/Application Support/RichOS/loro-root"`.
Delete it and the app boots exactly as it did this morning, saying so on three lines instead
of one. Nothing in the product creates it, no installer exists to create it, and inventing a
default would be the one inference `CONTEXT-CONTRACT.md` §1 forbids.

## 7. What was restored, so his first launch is his

Every file under `~/Library/Application Support/com.richos.app/` was copied out before
anything was run and copied back afterwards. `config.json` carries **no `entity` key**, so
his first launch asks him — nothing here chose a company on his behalf. The ledger is back
at its 10 original lines; the two threads and the one exchange in it are his, from earlier
today, and the turns driven for this note are gone with the restore.

## 8. WHAT IS NOT PROVEN HERE

- **Notarization.** There are no notary credentials on this machine — no
  `RICHOS_NOTARY_KEY`, no keychain profile. `spctl` therefore rejects the bundle, and a copy
  that arrives over a network WILL be blocked by Gatekeeper. Locally installed, it opens.
- **The typed turn on build 2 specifically.** §3 and §4's drive ran against build 1. Build 2
  is installed, was launched twice, and its boot line was read back under a faithful
  environment (§2) — but the login window came up before a second accessibility drive could
  run, and the accessibility API cannot reach a window behind it. What §5 closes is the code
  between them: the same crate, the same resolver, the same real `claude`, under the same
  launchd environment, answering. What is NOT claimed is a hand on build 2's composer, and
  the honest way to finish it is to double-click the installed app, pick a company and type a
  sentence — which is the thing this whole task exists to make possible.
- **A DMG.** `cargo tauri build --bundles app,dmg` fails with `error running bundle_dmg.sh`,
  exit 4, undiagnosed. The `.app` is the artifact that matters and it is the one built.
- **`RICHOS_SERVICE_BIN`.** Unset, so a spoken correction is recorded and asked and
  confirming it reports that there is no vocabulary to write to. Named on the boot line;
  unchanged by this work.
