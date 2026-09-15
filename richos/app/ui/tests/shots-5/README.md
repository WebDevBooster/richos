# `shots-5/` — the feedback channel, state by state

Written by `../feedback.js` out of WebKit's own compositor, every one decoded and
pixel-counted before it counted as evidence (`lib/harness.js`, rule 3). Overwritten on
every run and not byte-stable: read the suite's exit code, not a `git diff` over a PNG.

They exist because RICH-TODOs row 5's completion criterion is observable, not internal —
*the CEO can open the surface, give a rating, see the report offer appear only for 1 and 2,
read the exact anonymized text his RichOS would say, approve or refuse it, and find his own
answers recorded locally.* One shot per clause, plus the two honest states that are easiest
to get wrong.

| Shot | What it is evidence of |
|---|---|
| `5-01-the-question-and-four-keys.png` | The panel as he first meets it. The question is `PROMPT_QUESTION` and the four buttons are the module's own keys and labels — check 2 compares them to the Rust constants. No key is styled as the recommended answer. |
| `5-01b-the-offer-only-1-and-2-ever-see.png` | `REPORT_OFFER`, verbatim, after a `2`. Nothing has been recorded at this point: the offer is a question, not a record. |
| `5-02-a-good-rating-is-never-asked-for-more.png` | A `3`, recorded straight away, with no offer beneath it. `FeedbackEntry::with_report` would refuse a report attached to a `3`, so offering one would be inviting a refusal. |
| `5-03-the-whole-vocabulary-and-nowhere-to-type.png` | All twenty-one terms, and the feature itself made visible: there is no text field anywhere on this surface, because `FeedbackPayload` has no `String` at any depth for one to fill. |
| `5-04-exactly-what-would-be-said.png` | **The point of the feature.** The disclosure heading and the exact block — the whole block, with no nested scroller — before he is asked to approve anything. Byte-identical to `render_disclosure`'s output. |
| `5-05-approved-and-on-this-machine.png` | The same text back under "What's on this machine", re-rendered from the stored payload rather than from a second copy of the prose. |
| `5-06-refused-and-nothing-kept-about-it.png` | He said no. The rating is kept; the payload is dropped and the row carries no report. |
| `5-07-the-file-would-not-open.png` | The store would not open: the backend's own sentence, which names who owns the fix — and the four keys are NOT on screen, because asking him what he thinks and then dropping the answer is worse than not asking. |
| `5-08-three-answers-on-this-machine.png` | Three stored shapes a cargo test took through a real `FeedbackStore` round trip: a dismissal, a declined offer and an approval, each rendering as a different row. |
