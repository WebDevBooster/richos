# `shots-3-1/` — techy mode, state by state

Written by `../techy.js` out of WebKit's own compositor, every one decoded and
pixel-counted before it counted as evidence (`lib/harness.js`, rule 3). Overwritten on
every run and not byte-stable: read the suite's exit code, not a `git diff` over a PNG.

They exist because open-items row 3.1's completion criterion is observable, not internal —
*open a thread in the UI with techy mode on and see that turn's real machinery, the tool
calls and the status each actually returned, and toggle it off and on per thread.* One
shot per clause, plus the two empty states that are easiest to get wrong and are the whole
reason the four-state distinction exists.

| Shot | What it is evidence of |
|---|---|
| `3-1-01-off-nothing-changed.png` | The calm default, untouched. §3.3: *"No affordance in the conversation, at all, when off. A visible affordance IS a change to the default experience."* No chip, no chevron, no state line, and the word "technical" appears nowhere on screen. |
| `3-1-02-the-turns-real-machinery.png` | **The point of the feature.** One line per tool call, interleaved in the shared per-turn `seq` order between the message bubbles of the same turn — not a side panel, because the CEO is replacing a terminal and a terminal is one interleaved stream. Every title is the MERGED command, never the wire's opening placeholder (`Terminal`, `Preparing file…`), and every outcome is its own word: `done`, `failed`, `outcome not recorded`. The dim italic `usage_update` line is an untyped vendor kind, present here and absent from the calm view. |
| `3-1-03-one-switch-for-all-of-them.png` | The Settings line. §3.1: the CEO said "some **or all** of their conversations", so "all" has to be one switch. The conversation behind it is pinned OFF and stays off — a pin means something, which is the half of §7.1 a global-only build would lose. |
| `3-1-04-off-again-and-identical.png` | The same thread after toggling on, opening a raw pane, and toggling off. `#messages` innerHTML is compared byte for byte against the shot above it and is unchanged — §3.3's invariant measured rather than asserted. |
| `3-1-05-nothing-was-recorded-for-this-one.png` | A conversation from before the routing commit. *"No machinery was recorded for this conversation"* and *"this conversation had no machinery"* are different sentences and this is the first one. His conversation is still there; only the machinery column is empty. |
| `3-1-06-i-cannot-read-it-which-is-not-empty.png` | The state the brief named. The store is there and the OS refused it, and the sentence says so, names the owner, and says the record is not lost — with the operator-facing path underneath. Drawn in the palette's one non-accent state color so it cannot be mistaken for the shot above. |
| `3-1-07-the-output-and-the-two-honest-degrades.png` | §2.4's raw pane, all three answers at once: the retained payload; *"The full output isn't kept this long"* over a row whose Tier-B window has passed, with its normalized record above it untouched; and a prefix labelled as a prefix where the 32 KB cap fired. None of the three names a retention duration — §7.2 is the CEO's open question and a sentence saying "14 days" would answer it in copy. |
