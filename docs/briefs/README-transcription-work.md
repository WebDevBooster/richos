# The transcription measurement work lives in the PRIVATE record

The 2026-08-29 long-form transcription briefs — the 92-minute real-audio
measurement, the `-mc 0` long-form fix, and the Parakeet coverage benchmark —
are **not in this repository**, deliberately.

They are built on a recording of the CEO's own webinar: full transcripts of both
channels, a named third-party speaker, and business content. `open-source-strategy.md`
designates **this** repo as the one that goes public and states that development
runs in it. A transcript of a private call has no business here at any point,
regardless of the repo's visibility today.

The same applies to the **podcast-corpus measurement** of the same date, which is built on three
recordings of the CEO's own podcast — full transcripts, six per-speaker raw tracks, and three named
third-party guests — and to the **silence-fabrication fix** measured on the same six tracks.

They live in the private record instead:

    richos-hq/docs/briefs/norm-brief-real-audio-92min-2026-08-29.md
    richos-hq/docs/briefs/norm-brief-longform-fix-2026-08-29.md
    richos-hq/docs/briefs/norm-brief-parakeet-coverage-2026-08-29.md
    richos-hq/docs/briefs/norm-brief-podcast-corpus-2026-08-29.md
    richos-hq/docs/briefs/norm-brief-silence-fabrication-2026-08-29.md
    richos-hq/docs/briefs/norm-*-2026-08-29-assets/

**What DID land here, and is the product change itself:** decode context is now a
pipeline-wide invariant (`MAX_CONTEXT_TOKENS = 0` in `tools/richos-service/lib/config.js`),
the repetition guard gained a physical speech-burst veto, and — 2026-08-29, second pass — a
fourth class that REMOVES text emitted over measured silence, the defect that filled 60.4% of one
per-speaker channel's timeline with the phrase "Thank you.". Those carry no speech content: the
only corpus string quoted in the code is that filler itself, which is quotable precisely because
isolated re-decode under two decoders proved nobody said it.
`clark-brief-parakeet-viability-2026-08-29.md` also stays — it is a technology evaluation and
quotes nothing.

**The lesson, recorded because it was learned the hard way:** the source audio was
correctly gitignored at `docs/reference/local/` the whole time. The check that
failed was "no media committed" — applied three times, on three consecutive lands,
while the sensitive payload went in as text. **The privacy question is what the
bytes SAY, not what format they are in.**

**Two things the podcast-corpus measurement adds to that lesson**, because they
generalize beyond one incident:

1. **Result files are speech.** A measurement JSON that carries decoded span text
   is as disclosing as a transcript, and it arrives looking like data. That
   measurement redacts its results by a STRUCTURAL rule rather than by eye —
   span text survives only where isolated re-decode proved the words were
   fabricated over silence and were therefore never spoken by anybody; every
   other string becomes a word count.
2. **Test fixtures are the quiet leak.** It is very tempting to paste a real
   sentence into a unit test because it is the case that broke. Every "genuine
   speech" case in that harness is INVENTED, of the same shape as the corpus.
   An invented line of the same shape proves the same property.

**And one the silence-fabrication brief adds**, because it changes what the
structural rule in (1) has to test:

3. **"The isolated decode returned words" is not proof that speech was there.**
   Twelve spans in that run decoded, alone, to a *different* hallucination —
   whisper's broadcast filler over audio 44–63 dB below the channel peak, with
   two decoders disagreeing with each other about which invented phrase it was.
   A redactor keying on "did anything come back?" would have withheld twelve
   strings that are pure model output while a naive reader concluded the guard
   was eating speech. The redaction rule — and the acceptance rule — is
   therefore **"did the isolated decode recover the words being removed?"**.
