# The boot lines the entity registry added, classified — and the check re-proved

`app/scripts/gui-boot.test.sh` case **B2** went red when the entity-registry pass
(`8dde942` -> `ea91fa2`) gave the boot a new seam to speak about. B2 is the positive half of
that suite: every `[richos]` line a Finder-condition boot prints must be accounted for by a
rule, and a line nobody has classified is red by construction. That is the check working —
drift makes the unaccounted list LONGER, never shorter — and the repair is to decide what
each new sentence means, never to widen a rule until the red goes away.

This directory is the evidence for that pass. Everything in `raw/` is a captured run on the
operator's real `$HOME` on this Mac; only the scratch temp path is shortened to `<TMP>`.

| file | what it shows |
|---|---|
| `raw/1-red-at-9a7799e.txt` | RED FIRST. 17 passed, B2 FAILED: seven unaccounted lines and `NOT RESOLVED company`. |
| `raw/2-removing-the-registry-is-healed-by-the-migration.txt` | Why B8 corrupts the registry instead of deleting it. |
| `raw/3-green-at-33d8345.txt` | All 20 passed, with the classifications in force. |
| `raw/4-red-with-a-planted-line.txt` | A planted `eprintln!` in `main.rs`'s boot path: 1 FAILED, 19 passed, B2 naming the line verbatim. |
| `raw/5-run-tests-all-seven-suites-green.txt` | `app/scripts/run-tests.sh`: all 7 suites, 136 checks, exit 0. |
| `healthy-boot.txt` | The healthy boot log the suite's `healthy_log()` fixture is a transcript of. |

## How the true set of new lines was derived

Not from one boot. A boot only prints the lines its own conditions produce, so a list taken
from a terminal is a list of one machine's luck.

1. Every `eprintln!` literal in `app/src-tauri/src/*.rs` outside `#[cfg(test)]` was
   enumerated — 70 operator lines, the same scope the suite's `S1` case scans.
2. The two indirections a literal grep cannot see were followed. `main.rs:691` and
   `main.rs:878` both print `[richos] {note}`, and the notes are built in `richos-core`:
   `EntityRegistry::load` (`entity.rs:648-740`, seven sentences) and `resolve_boot_entity`
   (`main.rs:603-659`, four). **That is where the entity-registry lines live**, and it is why
   an inventory assembled from an observed boot misses them.
3. The result was diffed against the same enumeration at `07ed1d4`, the commit before the
   registry pass.

The seven-line list in the brief is a subset. It does not carry the four `Unreadable`
sentences, the two migration sentences, `RICHOS_ENTITY=… is not a registered entity`,
`no working directory could be read`, or the two `first-run setup` lines that print only
beside a missing component. Two of its seven — `entity not resolved from /` and `first-run
setup: nothing missing` — are not new source at all: both predate `07ed1d4` and had simply
never printed on a machine where the registry was compiled into the binary.

## The classifications

The reasoning lives beside each declaration in `app/scripts/gui-boot.test.sh`, where the
next person to see B2 go red will be reading. In summary:

**Proofs** (the boot is held to them; silence is a failure)

- `company registry: N compan(y|ies) from <path>` — reached on exactly one path in
  `EntityRegistry::load`: read, parsed, version-checked, every row validated, no id
  duplicated. Every other path pushes a different note and returns the EMPTY registry, so
  the absence of this sentence IS the presence of a refusal.
- `first-run setup: nothing missing.` — a claim about this machine that `setup_view::detect`
  went and checked, not a report of a setting.

**Routine facts** (state, with no claim that anything was verified)

- `company registry: N compan(ies), <path> (file)` — how many companies are on disk and
  where. **`(file)` only.** `(absent)` and `(unreadable)` are the same sentence about an
  install with no company list it can use; on a machine this check calls complete neither is
  an ordinary state.
- `launch: <kind> (start <n|->, <k> window(s))` — the existing pattern accepted only digits,
  and `start_ordinal()` is `None` for every launch that is not a counted start, so
  `(start -, 1 window(s))` was unaccounted. Invisible in the healthy boot, which is always
  `fresh`; visible in every one of B3-B8, where it read as noise beside a real failure.

**Declared gaps** — unchanged. `RICHOS_SERVICE_BIN` remains the only one.

**Refused — the fourth class, and it is executed rather than documented**

Twenty-one sentences are declared as lines that may never become rules, each with its
reason: the whole registry-refusal family, the migration pair, the four resolution failures,
both shapes of "nothing resolved" with their operator lines, and the three `first-run setup`
lines that only print beside a missing component. Case `A6` appends each one to the healthy
fixture and requires the accounting to refuse it BY NAME.

That case exists because the cheapest way to make B2 green is to widen a rule until it
swallows whatever is red. That repair is invisible in a passing run and it deletes the
check. A6 turns red on the run that widens one.

## Why B8 corrupts the registry rather than deleting it

Deleting `entities.json` does not break the machine, and `raw/2-…` is the measurement.
The machine has booted once, so its ledger holds a thread under `northwind`;
`registry_load.source` is `Absent`; the no-orphan migration (`main.rs:895`) re-registers the
ids that already own records; and the boot resolves normally, printing

    [richos] company registry: this install already had threads under 1 compan(ies) (northwind).

The file it writes back registers the id with `"roots": []` — no folder is guessed, exactly
as the code says. That is correct product behavior, and a negative case a repair path heals
proves nothing about the detector. So B8 leaves a file that exists and cannot be trusted —
the state the migration is deliberately gated against.

## One thing found and not fixed

`main.rs:637` builds the stale-saved-choice note with a run of eighteen spaces inside the
sentence:

    the saved company "northwind" is not a registered entity any more — ignoring it                  and asking again rather than filing work under a guess

It is a source-formatting artifact in an operator line, not a behavior defect. It is quoted
verbatim in the suite's `refused` declaration, which says so — this pass classifies what the
boot says and does not tidy the product's wording. Worth one edit by whoever owns that
sentence.
