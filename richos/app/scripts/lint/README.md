# Rust and shell lint

From the repository root:

```sh
bash richos/app/scripts/lint.sh --fast
bash richos/app/scripts/lint.sh --all
```

`--fast` runs ShellCheck, the project rules and Clippy for the core/voice workspace
and the detached updater. `--all` adds the detached Tauri workspace. All Clippy
commands use `--locked --all-targets` with default features. They type-check test
and example targets but do not run them or launch the app. Compiler warnings are
counted by diagnostic ID; compiler errors always fail. Rust settings warn during
ordinary compilation and the lint entry point refuses growth above the baseline.

Install ShellCheck 0.11.0 and the Clippy component for the Rust toolchain recorded
in the baseline. Python 3.11 or newer is needed for the TOML reader; its major/minor version is recorded
for the custom rules. Commands, versions, rules and scanned paths are visible in
`baselines/*.json`. Missing tools, empty inventories, invalid output and failed
compilation refuse the check. `CARGO_TARGET_DIR` is respected.

The tracked inventory includes shell scripts nested under `app/scripts`, Rust
files under `app` and JavaScript under `app/ui`. Every file has a language and a
role. Files in `fixture` or `fixtures` directories are recorded but excluded from
product scans. Test suites remain in the scan. The `suite-inputs` rule applies
only to top-level `*.test.sh` files discovered by the app script runner.

## Rules and limits

| Rule | Treatment | Supported evidence |
| --- | --- | --- |
| ShellCheck diagnostic IDs | Blocking count ceiling | ShellCheck's parser and documented rules |
| Rust/Clippy diagnostic IDs | Blocking count ceiling | Compiler and Clippy output for the recorded commands |
| `process-pattern-kill` | Blocking count ceiling | Direct `pkill` by name, `kill $(pgrep ...)`, simple scalar assignments and `for` variables carrying name-selected PIDs into `kill` |
| `process-self-wait` | Blocking count ceiling | Literal `sh -c` or `bash -c` wait whose literal `pgrep -f` pattern appears in that command line |
| `timeout-success` | Blocking count ceiling | Named timeout comparison followed immediately by literal `exit 0` in its `then` branch |
| `timeout-indirect` | Advisory | Such a branch delegates to a function or other control flow |
| `suite-inputs` | Blocking count ceiling | A discovered suite lacks a nonempty input declaration |
| `dialect` | Blocking count ceiling | Existing dialect hook's Write-payload verdict, preserving locale, quotation and ownership exemptions |
| `test-positive-control` | Advisory | A refusal assertion without an acceptance assertion recognized in that file |
| `test-retry` | Advisory | Retry or sleep syntax in a test; product retries can look identical |
| `ui-absence` | Advisory, JavaScript report only | A string that may assert an absence |

Structural shell checks cover the syntax above. They are not a shell interpreter
or a proof of arbitrary data flow. Heredoc contents, indirect functions, arrays
and `eval` are outside their contract. PID-only selectors and captured child PIDs
are not name selection. Positive controls can live in other files; a matching
assertion in the same file does not establish semantic adequacy. Advisory counts
never block. Public incident references live beside each project rule.

The dialect adapter invokes the existing hook rather than maintaining a second
dictionary or scanner. It observes the scanner-result assignment through shell
trace because the hook has silent stand-down and parse-failure paths. An
unevaluated scan fails. Trace stays in memory; normal output reports only the
result. Explicit exemptions in the hook remain valid.

## Maintaining the ceiling

Normal checks never edit baselines. Counts prevent a **net increase**, not every
new violation: fixing one and adding another can leave the same count.

```sh
bash richos/app/scripts/lint.sh --all --lower
git diff -- richos/app/scripts/lint/baselines
```

`--lower` proposes decreases as a working-tree diff for a separate reviewed
commit. It refuses growth. Comparison with `refs/heads/main` also rejects a
raised ceiling, removed rule, weakened classification or smaller inventory.
`--trusted-ref` selects another integration reference explicitly. That reference
must exist. Deleting a scanned file or changing a tool version requires an
explicit integration migration; a normal baseline update cannot silently waive
either. New files are scanned immediately, even before their inventory is added
with `--lower`. A new diagnostic ID starts at zero.

`--bootstrap` creates missing initial baselines only if they are also absent on
integration. Existing baselines are still checked, so an interrupted first run
can resume without replacing previously established ceilings. Initial ceilings
need review at introduction; there is no prior trusted ceiling to compare then.

`--static` runs only the shell and custom checks. It is useful during development
but does not satisfy the complete build gate. `--json-out FILE` writes detailed
findings and phase timings to an explicitly chosen report location. `--js-report`
reports JavaScript dialect matches and advisory candidates without enforcing a
JavaScript ceiling. It names shell-only rules that do not cover JavaScript.

## Build integration

The script runner discovers `lint.test.sh`, which runs the refusal/acceptance
fixtures and `lint.sh --all`: the fast set and Tauri Clippy. That suite is what a
land runs (`proof-for.sh` selects it for every change under `richos/app`), so the
land counts the same Tauri ceiling the nightly refuses on; with only the fast set,
a merge could pass its land and then stop the build. The nightly then invokes
`lint.sh --all` with its current suite receipt. Tauri Clippy runs every time. A passed fast-suite receipt
from the same nightly run avoids repeating fast lint. A missing, invalid or
skipped receipt runs fast lint again before Tauri Clippy. Receipt reuse requires
the nightly's execution marker; standalone `--all` runs both sets.
The lint never probes the parent's release lock or waits for the parent's load.
Scheduling standalone measurements is an operator responsibility.

The Tauri deadline is 180 seconds, including Cargo lock waiting.
Timeout cleanup terminates the process group created for the command, escalating
to a kill if needed. It never selects processes by name. Descendants that
deliberately detach into another session are outside process-group ownership.
A cold check may exceed the deadline and refuse; the cap does not promise that
cold compilation finishes within it.
