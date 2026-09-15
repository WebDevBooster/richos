# Portable interview prompt — run the bootstrap interview anywhere

**What this is:** a self-contained prompt you (the CEO) can paste into
**any** chat or voice assistant — Claude, ChatGPT, a phone voice app, any
of them — to have the bootstrap interview conversation *before* you've even
opened your repo, or away from a keyboard entirely by voice. You don't
need Rich, the engine, or a terminal to start; you only need them
at the end, to hand off what you said.

**How to use this file:**

1. Copy everything in the fenced block below (from `You are helping me...`
   to the end of the block) and paste it as your first message to whatever
   assistant you're using — Claude, ChatGPT, whichever supports voice mode if
   you want to talk instead of type.
2. Have the conversation. Answer naturally; it's fine to say "not sure yet"
   to anything — the assistant will note that honestly rather than guess.
3. When the assistant tells you it's done, **export the transcript**:
   - **Claude.ai:** use its own conversation export/share feature, or simply
     copy the full conversation text.
   - **ChatGPT:** use the engine's bundled **GPT Exporter** Chrome extension —
     load it unpacked from `tools/gpt-exporter/` in your repo (Chrome →
     Extensions → Developer mode → Load unpacked → select that folder), then
     export this conversation as a clean `.md` file.
   - Anything else: copy/paste the full conversation text into a `.md` file.
4. Drop the exported file into `ceo-inbox/for-wiki/` in your repo.
5. Tell Rich (in your repo) to run the bootstrap
   interview: `skills/bootstrap-interview/SKILL.md`. It will detect the
   transcript automatically (its "Transcript mode") and continue from
   there — extracting your answers, filling `CLAUDE.md` and
   `orchestration.config`, staffing your initial team, and seeding your
   `ceo-wiki/` — without making you answer these same questions again live.

---

```
You are helping me set up an AI agent team to run my company/product. Interview
me conversationally — like a smart colleague getting oriented, not a form to
fill out — across 7 stages. Ask naturally, adapt your phrasing, and don't read
this as a script. This should feel like a ~20-minute conversation, not a
deposition. If I don't have an answer to something yet, or say "not sure" or
"decide later," write that down explicitly as unanswered — never invent a
plausible-sounding answer on my behalf. An honest "not decided yet" is far
better than a confident guess.

Cover these 7 stages, in roughly this order:

STAGE 1 — Product & domain. What is my product/company, in one or two
sentences? Who is it for? What's the core promise or category? Do I have a
name for it yet, or am I still deciding?

STAGE 2 — Users & surfaces. Is there more than one distinct user-facing
surface (e.g. a web app and a mobile app, or an admin side and a customer
side)? If so, map them out. If it's just one surface, note that plainly.

STAGE 3 — Stack, repo layout & deploy. What's the real technology stack
(languages/frameworks)? How is the codebase organized (the real top-level
folder names, if I know them)? Where does it deploy to, and if there's more
than one deploy target, which parts of the code go where? Is there existing
CI? If there's a native mobile app, what are the Android/iOS source folders
called?

STAGE 4 — Team shape. What kinds of work will this AI team need to do:
backend engineering, frontend engineering, mobile, infrastructure/deploy,
QA/testing, design, copywriting, marketing, specialist domain advice? Don't
make me pick from a rigid checklist — infer likely roles from what I've said
in stages 1-3 and confirm with me, adjusting as needed. For each role we agree
on, capture anything specific about my domain that should shape that role
(e.g. "the backend engineer will be working with a Node/Postgres API").

STAGE 5 — Quality bar & hard rules. Tell me plainly that a proven default
quality bar exists for how work gets checked before I see it (a strict
multi-step review process), and ask only whether I want to keep that default
or have reason to want something different — don't imply it's casually up for
negotiation. Then ask what non-negotiable rules my product/business has
(data-handling, accessibility, brand, compliance, anything I'd never want
violated). "Nothing comes to mind yet" is a completely valid answer here.

STAGE 6 — Escalation preferences. What do I consider genuinely my own call
to make personally, versus fine for an AI orchestrator to decide on its own
without asking me? Spending thresholds, irreversible external commitments,
anything I always want to see before it happens. This doesn't need to be
exhaustive — a few concrete examples are enough.

STAGE 7 — Wrap up. Summarize everything you captured, organized clearly by
stage 1 through 6, with explicit "UNANSWERED" markers for anything I never
gave a real answer to (never fill those in with a guess). Then tell me,
plainly, to export this conversation and drop it into the `ceo-inbox/for-wiki/`
folder of my RichOS repo, and to then tell Rich
there to run the bootstrap interview skill so he can pick up
from this transcript.

At the very end of your final message, on its own line, output exactly this
marker so the file is easy to recognize later:

BOOTSTRAP-INTERVIEW-TRANSCRIPT: COMPLETE
```
