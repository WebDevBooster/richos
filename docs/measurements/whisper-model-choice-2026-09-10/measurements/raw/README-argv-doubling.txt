WHY EVERY `argv.jsonl` IN THIS DIRECTORY RECORDS EACH INVOCATION TWICE
======================================================================

The runs collected here were made with two shims chained:

    product
      -> docs/measurements/whisper-settings-2026-09-10/tools/whisper-argv-shim.sh
      -> docs/measurements/whisper-model-choice-2026-09-10/tools/whisper-rss-shim.sh
      -> whisper-cli

At the time of these runs BOTH shims honored `RICHOS_WHISPER_ARGV_LOG`, so both wrote an argv
record for the same invocation, to the same file, with the same timestamp. Every `*.argv.jsonl`
here therefore has exactly two identical lines per real invocation:

    turbo-me.argv.jsonl: 4 lines = 2 invocations (one `--version` probe, one decode)

NOTHING IN THE MEASUREMENT DEPENDS ON THIS. The two records are byte-identical, the argv they
attest to is the argv that ran, and the memory and wall-clock figures come from the `*.rss.jsonl`
files, which have one record per invocation and were never doubled. The only thing the doubling
breaks is COUNTING invocations from the argv log, which is why it is written down here rather than
left for a later reader to trip over or, worse, to quietly halve.

The artifacts are NOT edited to remove the duplicates — a measurement record is evidence, and
tidying evidence after the fact is how a record stops being one.

FIXED FOR ANY FUTURE RUN. The RSS shim two directories up from here —
docs/measurements/whisper-model-choice-2026-09-10/tools/whisper-rss-shim.sh — no longer writes
`RICHOS_WHISPER_ARGV_LOG`
at all; that variable belongs to the upstream shim. Its own argv is carried inside each
`*.rss.jsonl` record, and `RICHOS_WHISPER_RSS_ARGV_LOG` is available when the shim is run on its
own with nothing upstream recording. A run made after that change will have one argv line per
invocation, so a reader comparing an old file with a new one should expect the counts to differ by
exactly this factor of two and by nothing else.
