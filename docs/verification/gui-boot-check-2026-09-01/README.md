# Would this check have caught the three defects? — the answer, run rather than argued

`app/scripts/gui-boot.test.sh` boots the shipped binary under launchd's environment and holds
every line of its boot log to account. This directory is the proof that it works, and the
form of the proof is the one the brief demands: **each of the three defects already fixed on
2026-09-01 was put back, one at a time, and the check was run against it.** A check that
passes on today's code and has never been seen catching a known bug is a claim.

## The three premises, and the check's answer to each

| # | premise put back | commit that removed it | check | how it presented |
|---|---|---|---|---|
| 1 | `current_dir()/../engine` for the engine directory | `970ac5e` | **exit 1** | `[richos]   engine: /../engine` |
| 2 | `resolve_corpus` reads environment variables only | `c179cc1` | **exit 1** | `loro Tier C: no corpus configured` on a machine that has one |
| 3 | the desk's writer comes from `CliLoroWriter::from_env()` | `49e2cd4` | **exit 1** | **nothing.** One success line simply absent |

Raw output, each carrying the command that produced it:

- `raw/01-red-engine-directory.log`
- `raw/02-red-loro-read-path.log`
- `raw/03-red-loro-write-path.log`

## Number 3 is the one that matters

The write-path red run is the hardest case and the reason the check asserts two things
rather than one. Its boot log is this, in full:

```
[richos] launch: fresh (1 window(s))
[richos] company: femcboost (via the saved choice)
[richos] loro Tier C: compiling from <machine>/…/RichOS/corpus (via the corpus pointer in Application Support), node /opt/homebrew/bin/node
[richos] engine directory: <machine>/.claude/richos-engine (via engine install pointer)
[richos] compute lease attached over <machine>/.local/bin/claude
[richos] no RICHOS_SERVICE_BIN — spoken corrections will be recorded and asked, …
[richos] boot complete — every line above is what this launch resolved
```

**There is no bad sentence anywhere in it.** Every line is a healthy line. That is exactly
what `c6cf4ea` looked like on the CEO's installed app: the read half found his 626 records,
the write half found nothing, and the log said so by omission. A check that searched for
failure messages would have passed it.

What catches it is the second assertion — every RESOLVED rule must MATCH — and the output
is:

```
NOT RESOLVED  loro write half — nothing in this boot proved it was found.
              It should have said: the corpus a confirmed correction is written to (correction.rs, 49e2cd4)
```

Silence is not success.

## The healthy half, and why both halves are in the same suite

`raw/04-green-full-run.log` is the whole green run. Beside the positive case, five of the
fifteen checks are negative and run on **every invocation**: B3–B7 copy the healthy machine,
remove one configuration — the engine pointer, the corpus pointer, the loro tools, the
claude binary, the saved company — boot again, and require the check to go red. A one-sided
check is satisfied by a corpse, which is what the secret scanner was when it reported green
over a scanner that never ran. Those five prove five detectors are alive on the run you are
reading.

`A1`–`A5` do the same for the accounting function itself, against logs written by hand: an
unaccounted line fails and is printed verbatim, a missing success line fails, an empty log
fails rather than reporting "all 0 lines accounted for".

## One thing the red runs found in the check itself

The first version of the fixture found its loro compiler with `LoroInstall::locate` — the
boot's own resolution. Elegant, and wrong. Red run 2 breaks exactly that resolver, so the
fixture could not build a machine and the suite exited **2** saying *"this machine has no
loro compiler to copy"*. Red, so nothing failed open — and the **wrong diagnosis**, which
would have sent its reader hunting a missing checkout instead of the defect in front of him.

**A fixture must not be built by the component it tests.** `gui_compiler_source` in
`app/scripts/lib/gui-launch.sh` now finds it from facts that pass through no Rust code
(`$RICHOS_LORO_SOURCE`, the `loro-tools` install, `readlink` on the corpus pointer), and
`examples/gui_boot_machine.rs` only VALIDATES what it is handed, with `compiler_looks_valid`
— a predicate, not a search. Red run 2 was then re-taken and reports the real defect. That
finding is in `raw/02` and the reasoning is in both files' headers.

## Is it flaky?

`raw/05-five-consecutive-runs.log`: five consecutive runs, exit 0 every time, the same
fifteen verdicts line for line every time, 9 / 8 / 9 / 8 / 9 seconds.

Termination is a fact and not a sleep. `setup` prints `[richos] boot complete` as its last
act and the harness kills the process the moment that line lands; no marker within 60
seconds is exit 7 and a reported failure. A harness that slept for a fixed duration would
read a different amount of boot log on a busy machine than on an idle one — which is how a
blocking check becomes a formality by the third time it goes red for no reason.

## Where it runs

Locally, in `app/scripts/`, discovered by `run-tests.sh`'s `find` — there is no list to add
it to (`raw/06-run-tests-discovers-it.log`: 6 suites, 119 checks). **Not CI**: GitHub
Actions is disabled across this repository by CEO ruling, all five workflows are
`disabled_manually`, and `.github/workflows/README.md` records why — *a red cross that always
means nothing teaches people to ignore it* (`4a16e60`).

## What was not touched

Every path the suite creates hangs off a scratch `$HOME` under `mktemp -d`. The six files
under `~/Library/Application Support/com.richos.app` are byte-identical by sha256 before and
after every run recorded here, `~/Library/Application Support/RichOS/loro-root` still points
at `/Users/alex/ab/richos-hq`, and `~/ab/richos-hq` is clean. The CEO's 626 records were read
from — 37 files of `loro/` are copied out of them to give the scratch corpus a compiler — and
never written to.
