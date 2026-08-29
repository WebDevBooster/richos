# The transcription measurement work lives in the PRIVATE record

The 2026-08-29 long-form transcription briefs — the 92-minute real-audio
measurement, the `-mc 0` long-form fix, and the Parakeet coverage benchmark —
are **not in this repository**, deliberately.

They are built on a recording of the CEO's own webinar: full transcripts of both
channels, a named third-party speaker, and business content. `open-source-strategy.md`
designates **this** repo as the one that goes public and states that development
runs in it. A transcript of a private call has no business here at any point,
regardless of the repo's visibility today.

They live in the private record instead:

    richos-hq/docs/briefs/norm-brief-real-audio-92min-2026-08-29.md
    richos-hq/docs/briefs/norm-brief-longform-fix-2026-08-29.md
    richos-hq/docs/briefs/norm-brief-parakeet-coverage-2026-08-29.md
    richos-hq/docs/briefs/norm-*-2026-08-29-assets/

**What DID land here, and is the product change itself:** decode context is now a
pipeline-wide invariant (`MAX_CONTEXT_TOKENS = 0` in `tools/richos-service/lib/config.js`),
and the repetition guard gained a physical speech-burst veto. Those carry no
speech content. `clark-brief-parakeet-viability-2026-08-29.md` also stays — it is
a technology evaluation and quotes nothing.

**The lesson, recorded because it was learned the hard way:** the source audio was
correctly gitignored at `docs/reference/local/` the whole time. The check that
failed was "no media committed" — applied three times, on three consecutive lands,
while the sensitive payload went in as text. **The privacy question is what the
bytes SAY, not what format they are in.**
