# Speech model contract

## Authority

[`../models/model-pins.json`](../models/model-pins.json) is the single source table for
model IDs, filenames, exact byte sizes, SHA-256 values and their recorded provenance.
[`../provisioning/model-catalog.js`](../provisioning/model-catalog.js) exposes its existing
named exports. `PIN_FILE` names the actual canonical file. A caller-provided pin retains
the existing validation rules; unknown model names are refused before downloading.

The toolchain reference in the same table records the build used for measurements.
Its machine-specific binary hashes are reference observations, not universal required
binary hashes. Existing JavaScript and Rust toolchain implementations retain their
per-machine lock behavior and strict-mode options.

[`../models/model-costs.json`](../models/model-costs.json) records measured costs and
selection inputs. Memory and file sizes are bytes. Utterance duration is seconds;
long-form decoding rates are seconds of processing per second of audio. Each record
retains its measurement provenance. The table supplies live/batch ladders, the safe
rung, timing thresholds and probe data without creating another runtime state store.

## Consumers

| Consumer | Data and policy |
|---|---|
| Rust `toolchain.rs` | Compiles the pin table and uses the model hashes and toolchain reference |
| Rust `hardware.rs` | Compiles cost data; live selection uses the existing native measurements and probe rules |
| Service `model-catalog.js` compatibility import or direct component import | Same canonical module instance and pin objects |
| Service `hardware.js` | Reads canonical costs by default; explicit test/caller file injection is preserved |
| Dictation `fetch-dictation-models.sh` | Reads canonical pins with its existing shell parser; does not require Node or jq |

The full consumer test calls the actual compiled Rust readers through the
`model_metadata` example. It compares hashes and common cost fields with JavaScript
and compares the shell's model IDs, filenames, byte sizes and hashes with the catalog.
It does not assume live and batch model selection should make the same decision.

## Behavior retained

The catalog, integrity and fetch APIs preserve their export names and result/error
shapes. Downloads retain disk preflight, partial-file handling, bounded retries,
hash verification and rename-after-verification. A status check does not download a
model. Corrupt bytes do not become accepted merely because their size is correct.

Model directory searches, explicit model overrides, service decode settings and
speech toolchain lock/cache schemas remain with their existing consumers. This
component move does not reset a lock, move a recording or fetch new weights.
The JavaScript and shell download implementations remain separate consumers of
one pin table; consolidation does not introduce a new language bridge.
