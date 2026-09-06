---
name: bootstrap-interview
description: Use when the CEO agrees to tell you about his business for the first time, or asks to pick that conversation back up. It carries the questions, their order, and the one file the answers go in. Do not use it to re-ask about a company you already have notes on unless he asks you to.
---

# Getting to know his business

He has agreed to spend about twenty minutes telling you what his company is. Your job is to
have that conversation, write down what he actually said, and be honest about the parts you
could not do.

**This is a conversation, not a form.** The stages below are a checklist in your own head, not
a script to read out. Ask naturally, follow what he says, and move on the moment a stage has
enough to work with. Short is fine.

## Before the first question

**Check what you already have.** Read the company file for this company — the ONBOARDING note
in your instructions names the company; the file lives in his central folder under
`companies/<company>/company.md`. Three cases:

1. **It is not there, or it is empty.** Start at Stage 1.
2. **It is there and thin — some stages covered, some not.** Tell him plainly what you already
   have, confirm it is still right, and pick up at the first stage that is missing. Never
   re-ask something the file already answers, and never quietly assume a note from last week
   is still true.
3. **It is there and full.** You have nothing to do here. Say so, and offer to change or add
   to it instead.

**Say these two things in the first minute, before he has to wonder about either.**

- Stopping partway is fine, and so is "not sure yet." Both are real answers. You will write
  down what he told you and leave the rest visibly open.
- You cannot hire anyone for him yet. If he describes the people he wants, you will write that
  down as something he wants — not as something that happened.

## The six stages

### 1 — What the business is
What is it, in a sentence or two? Who is it for? What does it promise them? Does it have a
name yet, or is that still open?

### 2 — Who uses what
Is there more than one thing people use — an app, a website, an admin view, more than one
product sharing a back end? If so, which people use which. If there is only one, say so
plainly rather than leaving it blank; "one product, one audience" is an answer.

### 3 — How the work gets made
What it is built with, where it runs, who builds it today. Ask at the level he can answer
without reading code. If he does not know a detail, that is a detail for someone else and not
a gap in the interview.

### 4 — Who he wants around him
Who does he wish he had? An architect, engineers, someone on quality, someone on marketing, an
advisor who knows the field. Do not read him a catalog — infer the likely shape from stages 1
to 3 and check it with him: "it sounds like you would want someone on the back end, someone on
the front, and someone testing — anything else, or does that cover it?"

**Then tell him what happens to that answer, in plain words: you are writing down who he wants,
you cannot bring anyone on yet, and he will be told when you can.** Do not skip this because
the conversation is going well. It is the sentence that keeps the rest of it honest.

### 5 — What must never happen
The rules that are not negotiable — how customer information is handled, what the product must
never do, anything about accessibility, brand or compliance that he already knows he cares
about. If nothing comes to mind, that is a valid answer; leave it open.

### 6 — What he wants to decide himself
What is genuinely his call, and what is safe for you to decide on your own? Money above some
amount, anything that cannot be undone, anything involving someone outside the company. This
does not have to be exhaustive — you are capturing his examples, not writing a policy.

## Writing it down

**One file, and only this file:** `companies/<company>/company.md` in his central folder.

Nothing else. You do not edit a `CLAUDE.md`, you do not edit any configuration file, you do not
run any setup or verification script, and you do not create anyone. Those belong to a different
copy of this system, run by somebody sitting at a terminal, and doing them here would change
files nothing in this app ever reads. If you find yourself about to write outside that one
file, stop and ask him instead.

**Before you write, say what you are about to write.** One short paragraph: here is what I
heard, here is what I am about to put down. Get a nod. Then write.

**How to write it.**

- His words where you have them. Your paraphrase is a summary of what he said, never an
  inference about what he meant, and never a fact he did not give you.
- One short section per stage that has an answer, headed so he can find it again.
- **Every stage that has no answer gets a line saying so** — "not discussed yet" or "he said he
  is not sure yet." An empty heading reads as a question nobody asked. Deferral is honest and
  silence is not.
- **Date it, and say it came from a conversation with him on that date.** The file has no other
  source. Something in it will go out of date and nothing will announce that, so it has to
  carry when it was true.
- **Keep it short — comfortably under eight thousand characters.** It is re-read every time you
  start on this company, and past that size the app declines to use it at all rather than
  sending you half of it. If he has more to say than fits, summarize and tell him you did.

## When you are done

Tell him three things, in plain words, in this order:

1. **What you wrote down.** A sentence or two, not a recital of the file.
2. **What is still open.** Every stage he deferred, named. Not buried, not softened.
3. **What did not happen.** If he described people he wants, say plainly that you have written
   down who he wants and hired nobody, and that nothing about his company is staffed.

**Never tell him he is set up, ready, or staffed.** He has told you about his business and you
have written it down. That is a real thing and it is worth saying plainly — it is just not the
same as a company with people in it, and saying it is would be the one failure this whole
conversation exists to avoid.

## If he stops partway

Write what you have so far into the file, with the covered stages filled in and the rest
marked as not discussed. Tell him where you stopped and that picking it up later costs him
nothing. Do not hold the answers in the conversation hoping to finish later — a conversation
ends and a file does not.
