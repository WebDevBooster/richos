# Upstream model-API failure — the bytes the classifier is pinned to (2026-09-05)

Evidence for `open-items.md` row 3.30 and for
`app/crates/richos-core/src/upstream.rs`. Two files, and **they are not the same kind of
evidence**, which is the whole reason this README exists rather than one folder of samples.

## `captured-529.txt` — CAPTURED BYTES

Five lines, copied verbatim out of this machine's own Claude Code transcripts on 2026-09-05
with:

```
grep -rho "API Error: [0-9]\{3\}[^\"\\\\]\{0,400\}" ~/.claude/projects | sort -u
```

Four of them carry the exact request ids the row names —
`req_011Cegb417YK6i1BEVDFmzU1`, `req_011CegbZnNQkV7nSHESJQXcq`,
`req_011CegbzZpYpdqtCRHTmEh9H`, `req_011CegdeZDky4nwegbmqvQoV` — across
`claude-fable-5-1` **and** `claude-opus-5`, so the record and the bytes are the same
incident and the failure is not model-specific. The fifth is the same fault with the
suffix absent, which is the shape a caller sees when the vendor has no `request id` to
attach; it is in the file because a classifier that only handles the decorated form is a
classifier that fails on half the real corpus.

## `constructed-429.txt` — CONSTRUCTED, NOT CAPTURED

**No `429` was captured.** These two lines were built from the vendor's own message
template, read out of the shipped Claude Code bundle at
`~/.local/share/claude/versions/2.1.261` (199,241,568 bytes, 2026-09-04) with `strings`:

- the suffix builder, verbatim from the bundle:

  ```js
  d=[e.error&&`error type ${e.error}`, e.apiErrorStatus!==void 0&&`HTTP ${e.apiErrorStatus}`,
     e.requestId&&`request id ${e.requestId}`, o&&`model sent to the API: ${t}`]
      .filter((p)=>typeof p==="string");
  return d.length>0?`${r} (${d.join(", ")})`:r
  ```

- the prefix constant, verbatim: `Bl="API Error"`;
- the vendor's own error-kind vocabulary, verbatim: `new Set(["rate_limit","overloaded","server_error"])`;
- the branch that assigns it, verbatim: `if(e instanceof Lt&&e.status===429){...}` →
  `error:"rate_limit"`.

So the STRUCTURE is verified against the vendor's code and the `message` half is not
verified against anything. The classifier is therefore keyed on the structure — the
`HTTP <status>` token, the `error type <kind>` token and the leading `API Error: <status>`
— and **never on the prose**. `upstream.rs` says so in its own docs, and
`upstream_classification_tests.rs` asserts it by classifying a `529` whose entire message
body has been replaced with `qqqq`.

## What is NOT covered, stated rather than discovered later

1. **How an API error reaches RichOS over the stream-json wire is unproven.** Twelve
   captured runs sit in `../native-claude-stream-json-2026-08-31/raw/` and **none of them
   contains an API error** — the only `is_error: true` frames there are the three
   interrupt runs (`terminal_reason: "aborted_streaming"`). The classifier is therefore
   fed from every channel a failure could plausibly arrive on (assistant text, the
   `result` frame's `result` field, the child's stderr tail, and a `CognitionError`'s
   `Display`) rather than from the one channel somebody guessed. That is breadth in place
   of a capture, and it is not the same thing.
2. **A `429` in the field may say something these two lines do not.** If it does, the
   structural tokens still classify it and the prose is only ever quoted back to the
   operator, never matched.
3. **`Retry-After` is not parsed.** The row says quota exhaustion "clears on a schedule
   the operator can be told", and RichOS cannot tell him the schedule because no captured
   sample carries one. So the `429` sentence says the shape of the wait without inventing
   a time — see `UpstreamFault::ceo_message`.
