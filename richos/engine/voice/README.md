# Voice

**Shared speech infrastructure for Talk to Rich, dictation and call transcription.**

Voice is a major RichOS subsystem. This directory owns the shared model definitions,
model integrity checks and verified download machinery. It also maps the wider
subsystem, including the live conversation pipeline that remains in the app.

## Component map

| Location | Responsibility |
|---|---|
| [`models/`](models/) | Model identities, hashes, measured resource costs and selection parameters |
| [`provisioning/`](provisioning/) | JavaScript model catalog, integrity checks and verified downloads |
| [`tests/`](tests/) | Owned behavioral tests, consumer checks, relocation checks and isolated mutation audit |
| [`../../app/crates/richos-voice/`](../../app/crates/richos-voice/) | Live capture, speech detection, endpointing, echo cancellation, interruption handling, recognition and spoken playback |
| [`../../app/src-tauri/src/main.rs`](../../app/src-tauri/src/main.rs) | Desktop permissions, voice controller integration and connection to the persistent conversation |
| [`../../app/ui/`](../../app/ui/) | Talk controls and the voice interface |
| [`../../tools/richos-service/`](../../tools/richos-service/) | Recorded-call processing, service configuration and native host |
| [`../../tools/richos-hud/`](../../tools/richos-hud/) | Optional dictation application patches and its model installer |

**Talk to Rich** is a spoken mode of the same durable conversation used for text.
Dictation puts editable text into an input field. Call transcription processes
recordings. They share speech infrastructure while keeping their own workflows.
Voice does not own the conversation ledger, executive obligations or organizational
knowledge. Those remain with the app, ECS and Loro.

The [Rust pipeline overview](../../app/crates/richos-voice/src/lib.rs),
[examples](../../app/crates/richos-voice/examples/) and
[integration tests](../../app/crates/richos-voice/tests/) describe the live machinery.
The crate stays in its original Cargo workspace and does not call Node.

## Shared contracts

- [Speech models](contracts/speech-models.md): pin authority, measured cost data and workflow-specific selection.
- [Delivery](contracts/delivery.md): source layouts, compiled metadata and release dependencies.

The two JSON files are canonical source data. Rust embeds them at build time;
JavaScript and the dictation installer read their matching release's files.
Downloading an engine update does not change the metadata in an existing app binary.

## Verify locally

Use Node 24.21.0 or later. No npm dependencies need installing.

```sh
# From this directory, including an engine-only extraction:
npm test
npm run test:mutation

# From a complete product checkout with sibling app and tools:
npm run test:consumers    # requires Cargo; invokes the actual Rust readers
npm run test:relocation  # copied layouts and mutation-runner failure/interruption checks
```

The core suite uses small synthetic files and a loopback HTTP server. It does not
download speech models or open audio devices. The mutation audit captures a disposable
snapshot, mutates that copy and checks behavioral failures. It never resets the caller's
checkout. `npm run test:mutation -- --list` only lists its inventory.

From the service directory, `npm test` retains aggregate core and service coverage.
Its consumer subset prints that Rust conformance was not run; the full consumer command
above supplies that check. The service mutation command runs both component and consumer
mutations. Existing service JavaScript import paths forward to this component.

## Capability and delivery limits

This consolidation adds no speech model, new voice or automatic first-run model download.
It does not improve recognition accuracy or change latency settings. The live pipeline is
utterance-endpointed rather than a live partial transcript, and hardware-specific echo and
interruption limitations still apply. See the Rust overview for the current implementation.

A source test pass does not establish that a released app has its speech dependencies.
The [public download page](../../../.github/README.md) describes the released product.
The [consolidation receipt](../../../docs/verification/voice-consolidation-2026-09-16.md)
separates source checks from installed release acceptance.
