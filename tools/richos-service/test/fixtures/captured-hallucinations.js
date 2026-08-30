/**
 * REAL captured hallucination artifacts — the fixtures behind the hallucination-guard tests.
 *
 * GENERATED, not hand-written: every segment below is verbatim whisper.cpp output from the
 * 2026-08-26 call-length benchmark (`docs/briefs/norm-brief-q5-call-transcription-2026-08-26.md`
 * in the richos-hq record), copied from its JSON segment timeline with the original millisecond
 * offsets intact. Nothing here is a synthetic approximation of a failure — a fixture invented to
 * imitate an artifact proves nothing about the artifact.
 *
 * Provenance, sha256 of each source `whisper-cli -oj` JSON:
 *   C_turbo_rep1.json  648b8e28072d09a96d0bf4bad22a32ba8a461d66f0ec5ac1fec12e27721f7720
 *   C_turbo_rep2.json  648b8e28072d09a96d0bf4bad22a32ba8a461d66f0ec5ac1fec12e27721f7720
 *   C_turbo_rep3.json  648b8e28072d09a96d0bf4bad22a32ba8a461d66f0ec5ac1fec12e27721f7720
 *   C_q5_rep1.json     dd5d476b0f032e3226ec4193c1f4c9b9c1c9adf5534fdba3dcfec546c6a35fe3
 *   B_turbo_rep1.json  4f0689f12869e00e03a9120e9b316be54619c50b3a98b7b6f2f493daf52d7d80
 *   B_lv3_rep1.json    2b7cb7c738c31e5adf1edd20cf81bdeb25451fe6c5d466f5d658fd90985059de
 *
 * The three C_turbo reps are byte-identical (§7 of the brief) — the artifact is deterministic, not
 * a one-off, which is why one of them is a sufficient fixture.
 *
 * The raw benchmark artifacts themselves live outside this repo (the brief §12 records the scratch
 * directory); these fixtures are the durable copy of the parts that carry the failure.
 */

/** @typedef {{startMs:number, endMs:number, text:string, speaker:string}} Segment */

/**
 * CLASS 2 — PERSISTENT INSERTION, the full 88-segment far-side channel of `large-v3-turbo` on
 * sample C (11 min 24.8 s, band-limited + 15.0 dB SNR pink noise + 16 kbps opus).
 *
 * The model latched onto the genuinely spoken three-item action list at ~146 s and then prefixed a
 * fabricated, stalling ordinal onto 59 of these 88 segments, 151.6 s → 598.1 s. Two of those 59
 * markers are REAL: " 1." and " 3." at 151.6 s / 159.6 s are the speaker's own list. One more, the
 * " 0." at 205.3 s, is the speaker answering "Any data loss?" with "Zero." — inside the fabricated
 * span. That segment is the whole reason this class is detect-only.
 *
 * The FULL channel is kept because the verdict is channel-level: truncating it would change the
 * marker density the detector reasons about.
 * @type {Segment[]}
 */
export const TURBO_NUMERAL_INSERTION = [
  { startMs: 0, endMs: 6880, text: " Good morning, Marcus. It's Samantha Cole from Ridgeline Analytics. Thanks for making time for the quarterly technical review.", speaker: 'others' },
  { startMs: 7360, endMs: 15520, text: " Morning, Samantha. Happy to. I've got about 45 minutes before my next block, so let's use it well.", speaker: 'others' },
  { startMs: 15520, endMs: 28720, text: " Perfect. I want to cover four things today. The incident from last month, the migration status on Workspace W44192, the transcription model change, and then the renewal paperwork.", speaker: 'others' },
  { startMs: 29260, endMs: 39020, text: " That works. We start with the incident. My board is going to ask about it on Thursday, and I want to be able to answer properly.", speaker: 'others' },
  { startMs: 39020, endMs: 50780, text: " Absolutely. So the incident started on August 19th at 1:58 in the morning, Eastern Time. Your nightly extract transform load job kicked off as normal and began pulling call recordings.", speaker: 'others' },
  { startMs: 50780, endMs: 55820, text: " Right. That's the 4200 file patch we talked about.", speaker: 'others' },
  { startMs: 55820, endMs: 67580, text: " Exactly. What happened is that the queue worker requested a transcription slot from our fallback provider, and at that point the fallback was still pointed at Assembly AI rather than our self-hosted Whisper cluster.", speaker: 'others' },
  { startMs: 67580, endMs: 69340, text: " And Assembly AI rate limited you?", speaker: 'others' },
  { startMs: 69340, endMs: 83340, text: " They returned a 503 service unavailable, which is what you saw in your logs. The bug on our side was that the retry logic did not back off. It retried immediately, in a tight loop, about 1100 times before the job gave up.", speaker: 'others' },
  { startMs: 83340, endMs: 91100, text: " That explains the 1100 record number I kept seeing. I assumed record 1100 was corrupt.", speaker: 'others' },
  { startMs: 91100, endMs: 104860, text: " No, the record was fine. 1100 was just where the retry budget ran out. The fix shift as hotfix 2.7.4, and the change was to use exponential backoff with jitter, capped at 60 seconds.", speaker: 'others' },
  { startMs: 104860, endMs: 106860, text: " How did you catch it in the end?", speaker: 'others' },
  { startMs: 106860, endMs: 118860, text: " Our on-call engineer, Priya Habermeyer, got paged by pager duty at 2:11. The Grafana dashboard showed the queue depth climbing vertically, which is the signature of a retry storm rather than a slow consumer.", speaker: 'others' },
  { startMs: 118860, endMs: 124780, text: " 2:11. So 13 minutes to detection. That's not bad.", speaker: 'others' },
  { startMs: 124780, endMs: 139660, text: " 13 minutes to page, but 41 minutes to mitigation, which is the number I'm less happy about. The runbook pointed at the wrong dashboard. So Priya spent almost 20 minutes looking at the Postgres replica lag graph before she found the queue metrics.", speaker: 'others' },
  { startMs: 139660, endMs: 145660, text: " I appreciate you telling me that. Most vendors would have stopped at 13 minutes.", speaker: 'others' },
  { startMs: 145660, endMs: 151580, text: " We rewrote the runbook the same way. There are three action items from the postmortem, and all three are closed.", speaker: 'others' },
  { startMs: 151580, endMs: 159580, text: " 1. Exponential backoff with jitter. Shift in 2.7.4. 2. The runbook now links the queue depth dashboard first.", speaker: 'others' },
  { startMs: 159580, endMs: 167500, text: " 3. We added a synthetic canary job that runs the same extract path every 15 minutes against a five-file sample.", speaker: 'others' },
  { startMs: 167500, endMs: 171500, text: " The canary is the one I care about. Does it page?", speaker: 'others' },
  { startMs: 171500, endMs: 183420, text: " 3. It pages after two consecutive failures. So within 30 minutes of a real regression. And it runs against your tenant specifically, not just a shared test tenant, because your ingest path uses the dedicated queue.", speaker: 'others' },
  { startMs: 183420, endMs: 189340, text: " 3. Good. Put that in the summary email. My board will want the canary detail.", speaker: 'others' },
  { startMs: 189340, endMs: 201340, text: " 3. Will do. Second topic. The migration. Workspace W44192 is now fully on the new storage layer. That finished on the 22nd. Two days ahead of the window we agreed.", speaker: 'others' },
  { startMs: 201340, endMs: 205260, text: " 4. Any data loss? That was my worry the whole time.", speaker: 'others' },
  { startMs: 205260, endMs: 217260, text: " 0. We ran a full checksum comparison across all 140,000 objects. And every checksum matched. The verification report is attached to the migration ticket if your auditors want it.", speaker: 'others' },
  { startMs: 217260, endMs: 227260, text: " 4. They will. We re going to SOC 2 Type 2 right now, and the auditor has been asking for evidence of exactly that kind of control.", speaker: 'others' },
  { startMs: 227260, endMs: 236220, text: " 5. Then let me also send you the change management record. It shows who approved the migration, when, and the rollback plan we had ready.", speaker: 'others' },
  { startMs: 236220, endMs: 243180, text: " 5. That's helpful. While you're on compliance, are you still planning to support Okta for a single sign-on?", speaker: 'others' },
  { startMs: 243180, endMs: 253180, text: " 5. It's live already. Okta and Azure Active Directory both went generally available in build 3.0.2. If you want it enabled on your tenant I can request it today.", speaker: 'others' },
  { startMs: 253180, endMs: 259180, text: " 6. Let's do it. My security team will want to force it for all admin accounts.", speaker: 'others' },
  { startMs: 259180, endMs: 268140, text: " 6. I'll note that as an action item. Enforcement parole is supported. So you can require single sign-on for admins while leaving password login for read-only analysts.", speaker: 'others' },
  { startMs: 268140, endMs: 274140, text: " 7. No. Force it for everyone. If we're doing it, we're doing it properly.", speaker: 'others' },
  { startMs: 274140, endMs: 280140, text: " 7. Understood. Third topic. And this is the one I think will interest you most. The transcription model.", speaker: 'others' },
  { startMs: 280140, endMs: 288140, text: " 7. Yes. Last time we spoke we were going to flag my account for the large V3 Turbo batch too.", speaker: 'others' },
  { startMs: 288140, endMs: 296140, text: " 7. I did. And it's been running on Turbo since the 24th. I have 3 weeks of numbers now, which is enough to actually say something.", speaker: 'others' },
  { startMs: 296140, endMs: 298140, text: " 7. Give me the headline.", speaker: 'others' },
  { startMs: 298140, endMs: 307140, text: " 7. The overnight batch that used to take 4 hours and 10 minutes now takes 51 minutes. That's the whole 4200 file set. Transcribe then to end.", speaker: 'others' },
  { startMs: 307140, endMs: 311140, text: " 8. 51 minutes. That's inside our window with room to spare.", speaker: 'others' },
  { startMs: 311140, endMs: 321140, text: " 8. It is. And the accuracy did not move in a way we can measure. We sampled 200 calls, had them transcribed by both models, and had a human review the differences.", speaker: 'others' },
  { startMs: 321140, endMs: 323140, text: " 8. How many differences were there?", speaker: 'others' },
  { startMs: 323140, endMs: 337140, text: " 9. Across 200 calls there were 61 word level differences, and of those, our reviewer judged 19 to be in Turbo's favor, 22 in Full Large V3's favor, and 20 as ties where both were arguably correct.", speaker: 'others' },
  { startMs: 337140, endMs: 339140, text: " 9. So it's a loss.", speaker: 'others' },
  { startMs: 339140, endMs: 352140, text: " 9. Statistically, yes. The one place we do see a consistent gap is rare proper nouns. If your caller says a surname like Talvik or a product name we've never seen, Full Large V3 gets it right slightly more often.", speaker: 'others' },
  { startMs: 352140, endMs: 356140, text: " 9. Our callers say company names constantly. Should I be worried?", speaker: 'others' },
  { startMs: 356140, endMs: 368140, text: " 9. Not for your use case. And here's why. We're building a term biasing layer. You give us a list of names, products and account identifiers, and we feed them to the model as context before it transcribes.", speaker: 'others' },
  { startMs: 368140, endMs: 370140, text: " 10. Like a custom vocabulary?", speaker: 'others' },
  { startMs: 370140, endMs: 383140, text: " 10. Exactly like a custom vocabulary. It's the same mechanism the cloud vendors sell as a premium feature. For you it would mean uploading your customer list and your product catalog once, then refreshing it monthly.", speaker: 'others' },
  { startMs: 383140, endMs: 385140, text: " 11. When does that shift?", speaker: 'others' },
  { startMs: 385140, endMs: 395140, text: " 11. It's in build 3.1.0, which is scheduled for the end of next month. I'd like to put you on the early access list because your call volume makes you a good signal source.", speaker: 'others' },
  { startMs: 395140, endMs: 398140, text: " 11. Put me on it. What do you need from me?", speaker: 'others' },
  { startMs: 398140, endMs: 410140, text: " 11. A comma separated file with the terms. One per line. And a contact who can approve the data handling addendum. It's the same addendum you already signed for call recordings. So it should be quick.", speaker: 'others' },
  { startMs: 410140, endMs: 419140, text: " 11. Send it to me and I'll get it back to you listening. Now, the thing I actually need for Thursday. The Q3 retention numbers.", speaker: 'others' },
  { startMs: 419140, endMs: 428140, text: " 11. I pulled those this morning. Across the quarter you processed 19,480 calls. Up from 16,100 in Q2.", speaker: 'others' },
  { startMs: 428140, endMs: 431140, text: " 11. That's about a 20% increase.", speaker: 'others' },
  { startMs: 431140, endMs: 440140, text: " 21%. Yes. Of those, the sentiment classifier flagged 11% is at risk, which is down from 14% in Q2.", speaker: 'others' },
  { startMs: 440140, endMs: 443140, text: " 12. Done is good. Do we know why?", speaker: 'others' },
  { startMs: 443140, endMs: 454140, text: " 12. Two things. And I want to be careful here because one is measurable and one is inference. The measurable one is that your average handle time dropped by 40 seconds after the new routing rules went in.", speaker: 'others' },
  { startMs: 454140, endMs: 455140, text: " 12. And the inference?", speaker: 'others' },
  { startMs: 455140, endMs: 466140, text: " 12. The inference is that the drop in at risk sentiment tracks the handle time drop almost exactly. Quarter over quarter. That's a correlation. I can't tell you it's causal from the data I have.", speaker: 'others' },
  { startMs: 466140, endMs: 474140, text: " 12. I appreciate the distinction. My board will ask. And I'd rather say correlation than get caught overstating it.", speaker: 'others' },
  { startMs: 474140, endMs: 484140, text: " 12. One more number that will help you. Of the calls flagged as at risk, your team followed up within 24 hours on 78%. Last quarter that was 52%.", speaker: 'others' },
  { startMs: 484140, endMs: 492140, text: " 12. That's the one I'm proudest of. We changed the follow up queue to be a dedicated shift rather than best effort.", speaker: 'others' },
  { startMs: 492140, endMs: 498140, text: " 12. It shows. Let me send you all of these in a single deck so you're not assembling it from an email thread on Wednesday night.", speaker: 'others' },
  { startMs: 498140, endMs: 502140, text: " 12. Please. Last topic. The renewal.", speaker: 'others' },
  { startMs: 502140, endMs: 511140, text: " 12. Your term runs through November 30th. The renewal quote is with your procurement team. And it reflects the volume tier you've grown into rather than the one you signed at.", speaker: 'others' },
  { startMs: 511140, endMs: 512140, text: " 12. Meaning it went up.", speaker: 'others' },
  { startMs: 512140, endMs: 523140, text: " 12. The unit price went down. The total went up because your volume went up. At 19,000 calls a quarter you're in the second tier, which is 11 cents a minute instead of 14.", speaker: 'others' },
  { startMs: 523140, endMs: 525140, text: " 12. And if we hit 25,000?", speaker: 'others' },
  { startMs: 525140, endMs: 534140, text: " 9 cents. That tier starts at 25,000 calls per quarter, measured on a trailing three-month average, not a single quarter spike.", speaker: 'others' },
  { startMs: 534140, endMs: 541140, text: " 11. Drilling three-month. Good. That's fairer. Can you put the tier table in the deck as well?", speaker: 'others' },
  { startMs: 541140, endMs: 555140, text: " 12. I will. And one caveat I want to say out loud rather than vary in the quote. The 9-cent tier assumes batch transcription, not real-time. Real-time captions stay at the higher rate because they hold a model resident per stream.", speaker: 'others' },
  { startMs: 555140, endMs: 561140, text: " 12. That's fine. We barely use real-time. Maybe 5% of volume.", speaker: 'others' },
  { startMs: 561140, endMs: 565140, text: " 12. Then the blended rate works in your favor. I'll model both and show you the blend.", speaker: 'others' },
  { startMs: 565140, endMs: 568140, text: " 12. Great. Anything else on your list?", speaker: 'others' },
  { startMs: 568140, endMs: 578140, text: " 12. Two small things. First, we're deprecating the version 1 application programming interface on January 31st. You have 4 integrations still calling it.", speaker: 'others' },
  { startMs: 578140, endMs: 581140, text: " 12. Four? I thought we migrated everything.", speaker: 'others' },
  { startMs: 581140, endMs: 592140, text: " 13. Three are your own services and one is the snowflake connector, which we can update on our site. I'll send you the endpoint list with the last call timestamp for each so your team can find them.", speaker: 'others' },
  { startMs: 592140, endMs: 598140, text: " 13. Send that today if you need. That's the kind of thing that turns into a fire drill in January.", speaker: 'others' },
  { startMs: 598140, endMs: 615140, text: " 14. Today. Second thing. Your account identifier for the new billing system is B77310. The old workspace identifier W44192 still works everywhere in the product, but invoices will no reference B77310.", speaker: 'others' },
  { startMs: 615140, endMs: 621140, text: " Two identifiers for the same thing. That will confuse somebody in finance.", speaker: 'others' },
  { startMs: 621140, endMs: 635140, text: " It confuses me too, and I raised it. The plan is to unify them in the first quarter of next year. Until then, invoices say B77310 and everything else says W44192.", speaker: 'others' },
  { startMs: 635140, endMs: 658140, text: " Noted. I'll warn my controller. So to recap the actions, I'm sending you the postmortem summary with the canary detail, the migration checksum report, the change management record, the single sign on enforcement request for all roles, the early access agreement for term biasing in 3.1.0, the Q3 deck with the tier table, and the version 1 endpoint list.", speaker: 'others' },
  { startMs: 658140, endMs: 663140, text: " That's seven things. Can you number them in the email?", speaker: 'others' },
  { startMs: 663140, endMs: 667140, text: " Numbered. With owners and dates. Anything from your side?", speaker: 'others' },
  { startMs: 667140, endMs: 672140, text: " Just the term list in the addendum contact, and I'll get you both by Friday.", speaker: 'others' },
  { startMs: 672140, endMs: 678140, text: " Perfect. Marcus, thanks for the time, and genuinely thanks for the patience during the incident.", speaker: 'others' },
  { startMs: 678140, endMs: 682140, text: " You handled it well. Talk to you after the board meeting.", speaker: 'others' },
  { startMs: 682140, endMs: 684140, text: " Good luck Thursday. Bye now.", speaker: 'others' },
];

/**
 * NEGATIVE CONTROL for class 2, same 11-minute audio, byte-identical input, `large-v3-turbo-q5_0`:
 * 0 fabricated markers out of 91 segments. The slice below covers the same 15–31 region of the call
 * — i.e. the stretch where the other model's fabrication began.
 * @type {Segment[]}
 */
export const Q5_SAME_AUDIO_CLEAN = [
  { startMs: 140000, endMs: 146000, text: " I appreciate you telling me that. Most vendors would have stopped at 13 minutes.", speaker: 'others' },
  { startMs: 146000, endMs: 152000, text: " We rewrote the runbook the same way. There are three action items from the postmortem, and all three are closed.", speaker: 'others' },
  { startMs: 152000, endMs: 167700, text: " 1:1. Exponential back off with jitter. Shift in 2.7.4. 2: The runbook now links the queue depth dashboard first. 3: We added a synthetic canary job that runs the same extract path every 15 minutes against a five-file sample.", speaker: 'others' },
  { startMs: 167700, endMs: 171700, text: " The canary is the one I care about. Does it page?", speaker: 'others' },
  { startMs: 171700, endMs: 181300, text: " It pages after two consecutive failures, so within 30 minutes of a real regression. And it runs against your tenant specifically, not just a shared test tenant.", speaker: 'others' },
  { startMs: 181300, endMs: 184000, text: " Because your ingest path uses the dedicated queue.", speaker: 'others' },
  { startMs: 184000, endMs: 189800, text: " Good. Put that in the summary email. My board will want the canary detail.", speaker: 'others' },
  { startMs: 189800, endMs: 202500, text: " Will do. Second topic. The migration. Workspace W44192 is now fully on the new storage layer that finished on the 22nd. Two days ahead of the window we agreed.", speaker: 'others' },
  { startMs: 202500, endMs: 206600, text: " Any data loss? That was my worry the whole time.", speaker: 'others' },
  { startMs: 206600, endMs: 219100, text: " Zero. We ran a full checksum comparison across all 140,000 objects. And every checksum matched. The verification report is attached to the migration ticket if your auditors want it.", speaker: 'others' },
  { startMs: 219100, endMs: 228600, text: " Zero. They will. You're going to SOC2 type 2 right now, and the auditor has been asking for evidence of exactly that kind of control.", speaker: 'others' },
  { startMs: 228600, endMs: 236600, text: " Zero. Then let me also send you the change management record. It shows who approved the migration, when, and the rollback plan we had ready.", speaker: 'others' },
  { startMs: 236600, endMs: 243600, text: " That's helpful. While you're on compliance, are you still planning to support Okta for single sign-on?", speaker: 'others' },
  { startMs: 243600, endMs: 254100, text: " It's live already. Okta and Azure Active Directory both went generally available in build 3.0.2. If you want it enabled on your tenant, I can request it today.", speaker: 'others' },
  { startMs: 254100, endMs: 259600, text: " Let's do it. My security team will want to force it for all admin accounts.", speaker: 'others' },
  { startMs: 259600, endMs: 269100, text: " I'll note that as an action item. Enforcement parole is supported. So you can require single sign-on for admins while leaving password login for read-only analysts.", speaker: 'others' },
];

/**
 * NEGATIVE CONTROL for class 2, THE ONE THAT MATTERS: real speech carrying the same surface feature.
 * `large-v3-turbo` on sample B (the same script, clean audio), segments 15–30. The speaker
 * genuinely enumerates three action items and whisper renders them as segment-initial ordinals —
 * " 3. We added a synthetic canary job…" at 160.4 s is a legitimate segment-initial " 3. " marker,
 * byte-identical in surface form to the fabricated ones above.
 * @type {Segment[]}
 */
export const GENUINE_SPOKEN_ENUMERATION = [
  { startMs: 102380, endMs: 109460, text: " capped at 60 seconds. How did you catch it in the end? Our on-call engineer, Priya Havermeyer,", speaker: 'others' },
  { startMs: 109460, endMs: 115360, text: " got paged by pager duty at 2.11. The Grafana dashboard showed the queue depth climbing vertically,", speaker: 'others' },
  { startMs: 115780, endMs: 123040, text: " which is the signature of a retry storm rather than a slow consumer. 2.11. So 13 minutes to detection.", speaker: 'others' },
  { startMs: 123700, endMs: 131100, text: " That's not bad. 13 minutes to page, but 41 minutes to mitigation, which is the number I'm less happy about.", speaker: 'others' },
  { startMs: 131100, endMs: 136900, text: " The runbook pointed at the wrong dashboard. So Priya spent almost 20 minutes looking at the postger's", speaker: 'others' },
  { startMs: 136900, endMs: 142180, text: " replica lag graph before she found the queue metrics. I appreciate you telling me that.", speaker: 'others' },
  { startMs: 142700, endMs: 148440, text: " Most vendors would have stopped at 13 minutes. We rewrote the runbook the same week. There are", speaker: 'others' },
  { startMs: 148440, endMs: 154480, text: " three action items from the postmortem, and all three are closed. 1. Exponential backoff with jitter,", speaker: 'others' },
  { startMs: 154840, endMs: 160380, text: " shipped in 2.7.4. 2. The runbook now links the queue depth dashboard first.", speaker: 'others' },
  { startMs: 160380, endMs: 166820, text: " 3. We added a synthetic canary job that runs the same extract path every 15 minutes against a five-file", speaker: 'others' },
  { startMs: 166820, endMs: 171340, text: " sample. The canary is the one I care about. Does it page?", speaker: 'others' },
  { startMs: 171720, endMs: 177880, text: " It pages after two consecutive failures, so within 30 minutes of a real regression. And it runs against", speaker: 'others' },
  { startMs: 177880, endMs: 183940, text: " your tenant specifically, not just a shared test tenant, because your ingest path uses the dedicated queue.", speaker: 'others' },
  { startMs: 184180, endMs: 189620, text: " Good. Put that in the summary email. My board will want the canary detail.", speaker: 'others' },
  { startMs: 189620, endMs: 196060, text: " We'll do. Second topic. The migration. Workspace W44192", speaker: 'others' },
  { startMs: 196060, endMs: 202060, text: " is now fully on the new storage layer, that finished on the 22nd. Two days ahead of the window we agreed.", speaker: 'others' },
];

/**
 * CLASS 3 — SLIDING-OVERLAP STUTTER, verbatim segments 90–151 of `large-v3` (bare defaults) on
 * sample B. After a 7× verbatim loop at 324 s the decoder collapsed into re-emitting every phrase
 * two or three times with shifted boundaries for the remaining six minutes: 1,979 reference words
 * became 3,999 hypothesis words, 110.86 % WER. Consecutive segments are NOT identical, so the
 * repetition-loop detector removed only 6 of 353 segments.
 *
 * Note the zero-duration segments (`startMs === endMs`): those carry no audio at all.
 * @type {Segment[]}
 */
export const LARGE_V3_SLIDING_STUTTER = [
  { startMs: 349280, endMs: 349280, text: " or a product name we've never seen", speaker: 'others' },
  { startMs: 349280, endMs: 351680, text: " or a product name we've never seen full large v3 gets it right slightly more", speaker: 'others' },
  { startMs: 351680, endMs: 351680, text: " full large v3 gets it right slightly more", speaker: 'others' },
  { startMs: 351680, endMs: 354480, text: " full large v3 gets it right slightly more often our callers say company names", speaker: 'others' },
  { startMs: 354480, endMs: 354480, text: " often our callers say company names", speaker: 'others' },
  { startMs: 354480, endMs: 357520, text: " often our callers say company names constantly should i be worried not for", speaker: 'others' },
  { startMs: 357520, endMs: 357520, text: " constantly should i be worried not for", speaker: 'others' },
  { startMs: 357520, endMs: 359920, text: " constantly should i be worried not for your use case and here's why we're", speaker: 'others' },
  { startMs: 359920, endMs: 359920, text: " your use case and here's why we're", speaker: 'others' },
  { startMs: 359920, endMs: 362240, text: " your use case and here's why we're building a term biasing layer you give us", speaker: 'others' },
  { startMs: 362240, endMs: 364480, text: " building a term biasing layer you give us a list of names products and account", speaker: 'others' },
  { startMs: 364480, endMs: 364480, text: " a list of names products and account", speaker: 'others' },
  { startMs: 364480, endMs: 366640, text: " a list of names products and account identifiers and we feed them to the", speaker: 'others' },
  { startMs: 366640, endMs: 366640, text: " identifiers and we feed them to the", speaker: 'others' },
  { startMs: 366640, endMs: 369520, text: " identifiers and we feed them to the model as context before it transcribes", speaker: 'others' },
  { startMs: 369520, endMs: 369520, text: " model as context before it transcribes", speaker: 'others' },
  { startMs: 369520, endMs: 372720, text: " model as context before it transcribes like a custom vocabulary exactly like a", speaker: 'others' },
  { startMs: 372720, endMs: 372720, text: " like a custom vocabulary exactly like a", speaker: 'others' },
  { startMs: 372720, endMs: 375360, text: " like a custom vocabulary exactly like a custom vocabulary it's the same mechanism", speaker: 'others' },
  { startMs: 375360, endMs: 375360, text: " custom vocabulary it's the same mechanism", speaker: 'others' },
  { startMs: 375360, endMs: 377200, text: " custom vocabulary it's the same mechanism the cloud vendors sell as a premium", speaker: 'others' },
  { startMs: 377200, endMs: 377200, text: " the cloud vendors sell as a premium", speaker: 'others' },
  { startMs: 377200, endMs: 379200, text: " the cloud vendors sell as a premium feature for you it would mean uploading", speaker: 'others' },
  { startMs: 379200, endMs: 379200, text: " feature for you it would mean uploading", speaker: 'others' },
  { startMs: 379200, endMs: 380880, text: " feature for you it would mean uploading your customer list and your product", speaker: 'others' },
  { startMs: 380880, endMs: 380880, text: " your customer list and your product", speaker: 'others' },
  { startMs: 380880, endMs: 383840, text: " your customer list and your product catalog once then refreshing it monthly", speaker: 'others' },
  { startMs: 392240, endMs: 394080, text: " catalog once then refreshing it monthly list because your call volume makes you", speaker: 'others' },
  { startMs: 394080, endMs: 394080, text: " list because your call volume makes you", speaker: 'others' },
  { startMs: 394080, endMs: 397040, text: " list because your call volume makes you a good signal source put me on it", speaker: 'others' },
  { startMs: 397040, endMs: 397040, text: " a good signal source put me on it", speaker: 'others' },
  { startMs: 397040, endMs: 399200, text: " a good signal source put me on it what do you need from me a comma", speaker: 'others' },
  { startMs: 399200, endMs: 399200, text: " what do you need from me a comma", speaker: 'others' },
  { startMs: 399200, endMs: 401680, text: " what do you need from me a comma separated file with the terms one per", speaker: 'others' },
  { startMs: 401680, endMs: 401680, text: " separated file with the terms one per", speaker: 'others' },
  { startMs: 401680, endMs: 403920, text: " separated file with the terms one per line and a contact who can approve the", speaker: 'others' },
  { startMs: 403920, endMs: 403920, text: " line and a contact who can approve the", speaker: 'others' },
  { startMs: 403920, endMs: 406000, text: " line and a contact who can approve the data handling addendum it's the same", speaker: 'others' },
  { startMs: 406000, endMs: 406000, text: " data handling addendum it's the same", speaker: 'others' },
  { startMs: 406000, endMs: 407840, text: " data handling addendum it's the same addendum you already signed for call", speaker: 'others' },
  { startMs: 407840, endMs: 407840, text: " addendum you already signed for call", speaker: 'others' },
  { startMs: 407840, endMs: 410800, text: " addendum you already signed for call recordings so it should be quick send it", speaker: 'others' },
  { startMs: 410800, endMs: 410800, text: " recordings so it should be quick send it", speaker: 'others' },
  { startMs: 410800, endMs: 412800, text: " recordings so it should be quick send it to me and i'll get it back to you this", speaker: 'others' },
  { startMs: 412800, endMs: 412800, text: " to me and i'll get it back to you this", speaker: 'others' },
  { startMs: 412800, endMs: 413760, text: " to me and i'll get it back to you this week", speaker: 'others' },
  { startMs: 413760, endMs: 413760, text: " week", speaker: 'others' },
  { startMs: 413760, endMs: 416240, text: " week now the thing i actually need for", speaker: 'others' },
  { startMs: 416240, endMs: 416240, text: " now the thing i actually need for", speaker: 'others' },
  { startMs: 416240, endMs: 419760, text: " now the thing i actually need for thursday the q3 retention numbers i", speaker: 'others' },
  { startMs: 419760, endMs: 419760, text: " thursday the q3 retention numbers i", speaker: 'others' },
  { startMs: 419760, endMs: 421760, text: " thursday the q3 retention numbers i pulled those this morning across the", speaker: 'others' },
  { startMs: 421760, endMs: 421760, text: " pulled those this morning across the", speaker: 'others' },
  { startMs: 421760, endMs: 423760, text: " pulled those this morning across the quarter you processed nineteen thousand", speaker: 'others' },
  { startMs: 423760, endMs: 423760, text: " quarter you processed nineteen thousand", speaker: 'others' },
  { startMs: 423760, endMs: 425920, text: " quarter you processed nineteen thousand four hundred and eighty calls up from", speaker: 'others' },
  { startMs: 425920, endMs: 425920, text: " four hundred and eighty calls up from", speaker: 'others' },
  { startMs: 425920, endMs: 428560, text: " four hundred and eighty calls up from sixteen thousand one hundred in q2", speaker: 'others' },
  { startMs: 428560, endMs: 428560, text: " sixteen thousand one hundred in q2", speaker: 'others' },
  { startMs: 428560, endMs: 431360, text: " sixteen thousand one hundred in q2 that's about a twenty percent increase", speaker: 'others' },
  { startMs: 431360, endMs: 431360, text: " that's about a twenty percent increase", speaker: 'others' },
  { startMs: 431360, endMs: 434240, text: " that's about a twenty percent increase twenty one percent yes of those the", speaker: 'others' },
];

/**
 * NEGATIVE CONTROL for class 3: real clean speech from the same call. Across ALL 18 clean
 * turbo/q5_0 transcripts of the benchmark (3 samples × 2 models × 3 reps) the longest word-exact
 * overlap across ANY segment boundary was ZERO words — whisper segments partition the token stream.
 * @type {Segment[]}
 */
export const CLEAN_NO_BOUNDARY_OVERLAP = [
  { startMs: 275380, endMs: 281380, text: " Understood. Third topic, and this is the one I think will interest you most, the transcription model.", speaker: 'others' },
  { startMs: 281380, endMs: 287980, text: " Yes. Last time we spoke you were going to flag my account for the Large V3 Turbo batch tier.", speaker: 'others' },
  { startMs: 287980, endMs: 295980, text: " I did. And it's been running on Turbo since the 24th. I have three weeks of numbers now, which is enough to actually say something.", speaker: 'others' },
  { startMs: 295980, endMs: 297980, text: " Give me the headline.", speaker: 'others' },
  { startMs: 297980, endMs: 306980, text: " The overnight batch that used to take 4 hours and 10 minutes now takes 51 minutes. That's the whole 4200 file set, transcribed end-to-end.", speaker: 'others' },
  { startMs: 306980, endMs: 312580, text: " 51 minutes. That's inside our window with room to spare.", speaker: 'others' },
  { startMs: 312580, endMs: 321580, text: " It is. And the accuracy did not move in a way we can measure. We sampled 200 calls, had them transcribed by both models, and had a human review the differences.", speaker: 'others' },
  { startMs: 321580, endMs: 324180, text: " How many differences were there?", speaker: 'others' },
  { startMs: 324180, endMs: 337180, text: " Across 200 calls there were 61 word level differences, and of those, our reviewer judged 19 to be in Turbo's favor, 22 in Full Large V3's favor, and 20 as ties where both were arguably correct.", speaker: 'others' },
  { startMs: 337180, endMs: 338180, text: " So it's a wash.", speaker: 'others' },
  { startMs: 338180, endMs: 351780, text: " Statistically, yes. The one place we do see a consistent gap is rare proper nouns. If your caller says a surname like Talvik or a product name we've never seen, Full Large V3 gets it right slightly more often.", speaker: 'others' },
  { startMs: 351780, endMs: 355780, text: " Our callers say company names constantly. Should I be worried?", speaker: 'others' },
  { startMs: 355780, endMs: 369380, text: " Not for your use case. And here's why. We're building a term biasing layer. You give us a list of names, products and account identifiers. And we feed them to the model as context before it transcribes.", speaker: 'others' },
  { startMs: 369380, endMs: 371380, text: " Like a custom vocabulary.", speaker: 'others' },
  { startMs: 371380, endMs: 383380, text: " Exactly like a custom vocabulary. It's the same mechanism the cloud vendors sell as a premium feature. For you it would mean uploading your customer list and your product catalog once, then refreshing it monthly.", speaker: 'others' },
  { startMs: 383380, endMs: 384980, text: " When does that shift?", speaker: 'others' },
  { startMs: 384980, endMs: 394980, text: " It's in build 3.1.0, which is scheduled for the end of next month. I'd like to put you on the early access list because your call volume makes you a good signal source.", speaker: 'others' },
  { startMs: 394980, endMs: 398180, text: " Put me on it. What do you need from me?", speaker: 'others' },
  { startMs: 398180, endMs: 410180, text: " A comma separated file with the terms, one per line, and a contact who can approve the data handling addendum. It's the same addendum you already signed for call recordings, so it should be quick.", speaker: 'others' },
  { startMs: 410180, endMs: 419380, text: " Send it to me and I'll get it back to you this week. Now, the thing I actually need for Thursday. The Q3 retention numbers.", speaker: 'others' },
];

/**
 * CLASS 2 REPAIR EVIDENCE — the 57 suspect markers of `TURBO_NUMERAL_INSERTION`, each decoded ALONE.
 *
 * GENERATED, not hand-written, and generated by the PRODUCT: `normalize.js#cutSpan` cut each
 * segment's own span out of the sample-C wav at the two shipped paddings (0.3 s tight, 0.75 s wide)
 * and `transcribe.js#transcribeClips` decoded all 114 clips in one `large-v3-turbo` invocation at
 * the shipped decode args. Nothing below is an approximation of what an isolated decode returns.
 *
 * Source audio: the 2026-08-26 benchmark's `audio/C_call_16k_mono.wav` (sample B band-limited +
 * 15.0 dB SNR pink noise + a 16 kbps opus round trip; construction in that brief's §12). It is
 * macOS `say` TTS of an invented script, which is why GROUND TRUTH is known rather than judged:
 * `ref/B_script.tsv` says the speaker uttered "One,", "Two," and "Three," at the action list and
 * "Zero." answering "Any data loss?" — and of those, only the "Zero." at 205.3 s falls inside the
 * span the detector judges fabricated. Every other one of the 57 markers is invented.
 *
 * READ WHAT THE `index: 24` ROW SAYS. Decoded alone, that span returns the word "zero" — SEVEN
 * words in, because the fabricated decode put the segment boundary 1.7 s early. It is the reason
 * the strip rule looks at the whole clip instead of its head, and it is the single row that decides
 * whether this class can repair at all.
 *
 * @type {{index:number, value:number, tight:string, wide:string}[]}
 */
export const TURBO_NUMERAL_INSERTION_ISOLATED_DECODES = [
  { index: 20, value: 3, tight: "It pages after two consecutive failures, so within 30 minutes of a real regression. And it runs against your tenant specifically. Not just a shared test tenant, because your ingest path uses the dedicated", wide: "It pages after two consecutive failures, so within 30 minutes of a real regression. And it runs against your tenant specifically, not just a shared test tenant, because your ingest path uses the dedicated queue." },
  { index: 21, value: 3, tight: "Good. Put that in the summary email. My board will want the canary details.", wide: "Good. Put that in the summary email. My board will want the canary detail." },
  { index: 22, value: 3, tight: "detail will do second topic the migration workspace w44192 is now fully on the new storage layer that finished on the 22nd two days ahead of the winter", wide: "canary detail. Will do. Second topic, the migration. Workspace W44192 is now fully on the new storage layer that finished on the 22nd. Two days ahead of the window we have" },
  { index: 23, value: 4, tight: "ahead of the window we agreed and he paid the loss that was my woe", wide: "days ahead of the window we agreed and he paid the loss that was my worry before" },
  { index: 24, value: 0, tight: "my worries the whole time zero we ran a full checksum comparison across all 140,000 objects and every checksum match the verification report is attached to the migration ticket if", wide: "That was my worry the whole time. Zero. We ran a full checksum comparison across all 140,000 objects, and every checksum matched. The verification report is attached to the migration ticket if you're audited." },
  { index: 25, value: 4, tight: "ticket if your auditors want it. They will. We are going to SOC 2 Type 2 right now, and the auditor has been asking for evidence of exactly the kind.", wide: "migration ticket if your auditors want it they will you're going to SOC 2 type 2 right now and the auditor has been asking for evidence of exactly the kind of control" },
  { index: 26, value: 5, tight: "that timed and controlled. Then let me also send you the change management record. It shows who approved the migration, when, and the rollback plan we had ready.", wide: "That is the kind of control. Then let me also send you the change management record. It shows who approved the migration, when, and the rollback plan we had ready." },
  { index: 27, value: 5, tight: "That's helpful. While you're on compliance, are you still planning to support Octa for a single sign-on?", wide: "That's helpful. While you're on compliance, are you still planning to support Octa for single sign-on?" },
  { index: 28, value: 5, tight: "sign-on? It's live already. Okta and Azure Active Directory both went generally available in build 3.0.2. If you want it enabled on your tenant I can request it today.", wide: "It's live already. Okta and Azure Active Directory both went generally available in build 3.0.2, if you want it enabled on your tenant I can request it today." },
  { index: 29, value: 6, tight: "Let's do it. My security team will want to force it for all admin accounts.", wide: "I can request it today. Let's do it. My security team will want to force it for all admin accounts." },
  { index: 30, value: 6, tight: "I'll note that as an action item. Enforcement parole is supported, so you can require single sign-on for admins while leaving password login for read-only and", wide: "I'll note that as an action item. Enforcement parole is supported, so you can require single sign-on for admins while leaving password login for read-only analysts." },
  { index: 31, value: 7, tight: "read only analyst no force it for everyone if you're doing it you're doing it right", wide: "login for read-only analysts no course it's for everyone if we're doing it we're doing it properly" },
  { index: 32, value: 7, tight: "doing it properly. Understood. Third topic, and this is the one I think will interest you most, the transcripts", wide: "We're doing it properly. Understood. Third topic, and this is the one I think will interest you most, the transcription model." },
  { index: 33, value: 7, tight: "Yes. Last time we spoke we were going to flag my account for the largely three-truple-batch-2.", wide: "The transcription model. Yes. Last time we spoke, you were going to flag my account for the Largy3 Purple Hatch 2. I did." },
  { index: 34, value: 7, tight: "I did. And it's been running on turbo since the 24th. I have three weeks of numbers now, which is enough to actually say something.", wide: "I did, and it's been running on turbo since the 24th. I have three weeks of numbers now, which is enough to actually say something." },
  { index: 35, value: 7, tight: "Give me the headline.", wide: "say something. Give me the headline." },
  { index: 36, value: 7, tight: "the overnight batch that used to take 4 hours and 10 minutes now takes 51 minutes that's the whole 4200 file set transcribed then to end", wide: "the overnight batch that used to take four hours and ten minutes now takes 51 minutes that's the whole 4200 file set transcribed then to end" },
  { index: 37, value: 8, tight: "to end 51 minutes that's inside our window with room", wide: "drive then to end 51 minutes that's inside our window with room to stay" },
  { index: 38, value: 8, tight: "only room to stare it is and the accuracy did not move in a way we can measure we sampled 200 calls had them transcribed by both models and had a human review the", wide: "It is, and the accuracy did not move in a way we can measure. We sampled 200 calls, had them transcribed by both models, and had a human review the difference" },
  { index: 39, value: 8, tight: "and review the differences.", wide: "Let a human review the differences." },
  { index: 40, value: 9, tight: "How many differences were there? Across 200 calls there were 61 word level differences, and of those, our reviewer judged 19 to be in turbo's favor, 22 in full large V3's favor, and 20 as ties where both were arguably correct.", wide: "How many differences were there? Across 200 calls there were 61 word level differences, and of those, our reviewer judged 19 to be in turbo's favor, 22 in full large V3's favor, and 20 as ties where both were arguably correct." },
  { index: 41, value: 9, tight: "So it's a loss.", wide: "- We're arguably correct. - So it's a loss." },
  { index: 42, value: 9, tight: "loss statistically yes the one place we do see a consistent gap is rare proper nouns if your caller says a surname like talvik or a product name we've never seen full large v3 gets it right slightly more often", wide: "So it's a loss? Statistically, yes. The one place we do see a consistent gap is rare proper nouns. If your caller says a surname like Talvik or a product name we've never seen, Bulllarge V3 gets it right slightly more often." },
  { index: 43, value: 9, tight: "Our callers say company names constantly. Should I be worried?", wide: "more often our callers say company names constantly should I be worried" },
  { index: 44, value: 9, tight: "Not for your use case. And here's why. We're building a term biasing layer, you give us a list of names, products and account identifiers, and we feed them to the model as context before it translates.", wide: "should I be worried not for your use case and here's why we're building a term biasing layer you give us a list of names products and account identifiers and we feed them to the model as context before it transcribes" },
  { index: 45, value: 10, tight: "before it transcribes.", wide: "text before it transcribes." },
  { index: 46, value: 10, tight: "a custom vocabulary exactly like a custom vocabulary it's the same mechanism the cloud vendors sell as a premium feature for you it would mean uploading your customer list and your product catalog once then refreshing it monthly", wide: "Like a custom vocabulary? Exactly like a custom vocabulary. It's the same mechanism the cloud vendors sell as a premium feature. For you it would mean uploading your customer list and your product catalog once, then refreshing it monthly." },
  { index: 47, value: 11, tight: "it monthly. When does that shift?", wide: "refreshing it monthly when does that shift it's in build" },
  { index: 48, value: 11, tight: "It's in build 3.1.0, which is scheduled for the end of next month. I'd like to put you on the early access list because your call volume makes you a good signal source.", wide: "It's in build 3.1.0, which is scheduled for the end of next month. I'd like to put you on the early access list because your call volume makes you a good signal source." },
  { index: 49, value: 11, tight: "source put me on it what do you need from me", wide: "signal source. Put me on it. What do you need from me?" },
  { index: 50, value: 11, tight: "A comma separated file with the terms, one per line, and a contact who can approve the data handling addendum. It's the same addendum you already signed for call recordings, so it should be quick.", wide: "a comma separated file with the terms one per line and a contact who can approve the data handling addendum it's the same addendum you already signed for call recordings so it should be quick" },
  { index: 51, value: 11, tight: "Send it to me and I'll get it back to you this week. Now, the thing I actually need for Thursday, the Q3 retention numbers.", wide: "Send it to me and I'll get it back to you this week. Now, the thing I actually need for Thursday, the Q3 retention numbers." },
  { index: 52, value: 11, tight: "I pulled those this morning. Across the quarter you processed 19,480 calls, up from 16,100 in Q2.", wide: "I told those this morning. Across the quarter you processed 19,480 calls, up from 16,100 in Q2." },
  { index: 53, value: 11, tight: "That's about a 20% increase.", wide: "That's about a 20% increase." },
  { index: 55, value: 12, tight: "- Two. - Done is good. Do you know why?", wide: "in Q2 done is good do you know why? two things" },
  { index: 56, value: 12, tight: "Two things, and I want to be careful here because one is measurable and one is inference. The measurable one is that your average handle time dropped by 40 seconds after the new routing rules went in.", wide: "two things and I want to be careful here because one is measurable and one is inference the measurable one is that your average handle time dropped by 40 seconds after the new routing rules went in" },
  { index: 57, value: 12, tight: "And the end wins.", wide: "They went in. And the end was?" },
  { index: 58, value: 12, tight: "The inference is that the drop in at risk sentiment tracks the handle time drop almost exactly, quarter over quarter, that's a correlation, I can't tell you it's causal from the data I have.", wide: "The inference? The inference is that the drop in at risk sentiment tracks the handle time drop almost exactly, quarter over quarter. That's a correlation. I can't tell you it's causal from the data I have." },
  { index: 59, value: 12, tight: "I appreciate the distinction. My board will ask, and I'd rather say correlation than get caught overstating it.", wide: "I appreciate the distinction, my board will ask, and I'd rather say correlation than get caught overstating it." },
  { index: 60, value: 12, tight: "One more number that will help you. Of the calls flagged as at risk, your team followed up within 24 hours on 78%. Last quarter that was 52%.", wide: "stay tuned. One more number that will help you. Of the calls flagged as at risk, your team followed up within 24 hours on 78%, last quarter that was 52%." },
  { index: 61, value: 12, tight: "That's the one I'm proudest of. We changed the power of Pew to be a dedicated shift rather than best effort.", wide: "That's the one I'm proudest of. We changed the follow-up queue to be a dedicated ship rather than best effort." },
  { index: 62, value: 12, tight: "It shows. Let me send you all of these in a single deck so you're not assembling it from an email thread on Wednesday night.", wide: "It shows. Let me send you all of these in a single deck so you're not assembling it from an email thread on Wednesday night." },
  { index: 63, value: 12, tight: "on Wednesday night. Please. Last topic, the renewal.", wide: "Thread on Wednesday night, please last topic the renewal your time" },
  { index: 64, value: 12, tight: "Your term runs through November 30th. The renewal quote is with your procurement team, and it reflects the volume tier you've grown into rather than the one you signed at.", wide: "Your term runs through November 30th. The renewal quote is with your procurement team, and it reflects the volume tier you've grown into rather than the one you signed at." },
  { index: 65, value: 12, tight: "I didn't find that.", wide: "the one you signed at. - Meaning it went off." },
  { index: 66, value: 12, tight: "meaning it went up. The unit price went down, the total went up because your volume went up. At 19,000 calls a quarter you're in the second tier, which is 11 cents a minute instead of 14.", wide: "Meaning it went up. The unit price went down. The total went up because your volume went up. At 19,000 calls a quarter, you're in the second tier, which is 11 cents a minute instead of 14." },
  { index: 67, value: 12, tight: "And this we hit 25,000.", wide: "14 and if we hit 25,000" },
  { index: 69, value: 11, tight: "DRAIL IN GREEN ONE, GOOD, THAT'S FAIRER, CAN YOU PUT THE CURE TABLE IN THE DECK AS WELL?", wide: "You put the tier table in the deck as well?" },
  { index: 70, value: 12, tight: "As well? I will. And one caveat I want to say out loud rather than vary in the quote. The nine-cent tier assumes batch transcription, not real-time. Real-time captions stay at the higher rate because they hold a model resident per stream.", wide: "the deck as well I will and one caveat I want to say out loud rather than vary in the quote the 9 cent tier assumes batch transcription not real-time real-time captions stay at the higher rate because they hold a model resident per stream" },
  { index: 71, value: 12, tight: "That's fine, we barely use real time. Maybe 5% of volume.", wide: "stream that's fine we barely use real-time maybe five percent of volume then the blended" },
  { index: 72, value: 12, tight: "Then the blended rate works in your favor I'll model both and show you the blend", wide: "Then the blended rate works in your favor. I'll model both and show you the blend." },
  { index: 73, value: 12, tight: "Great. Anything else on your list?", wide: "- Great. Anything else on your list? - Too small." },
  { index: 74, value: 12, tight: "Two small things. First, we're deprecating the version 1 application programming interface on January 31st. You have four integrations still calling it.", wide: "Two small things. First, we're deprecating the version 1 application programming interface on January 31st. You have 4 integrations still calling it." },
  { index: 75, value: 12, tight: "it or i thought you migrated everything", wide: "calling it. Or? I thought we migrated everything." },
  { index: 76, value: 13, tight: "everything three are your own services and one is the snowflake connector which we can update on our site i'll send you the endpoint list with the last call timestamp for each so your team can find them", wide: "3 are your own services and one is the Snowflake Connector, which we can update on our site. I'll send you the endpoint list with the last call timestamp for each so your team can find them." },
  { index: 77, value: 13, tight: "Send that today if you do, that's the kind of thing that turns into a fire drill in January.", wide: "send that today if you can, that's the kind of thing that turns into a fire drill in January" },
  { index: 78, value: 14, tight: "Today, second thing, your account identifier for the new billing system is B77310. The old workspace identifier W44192 still works everywhere in the product, but invoices will no reference B77310.", wide: "January. Today, second thing, your account identifier for the new billing system is B77310. The old workspace identifier W44192 still works everywhere in the product, but invoices will no reference B77310." },
];
