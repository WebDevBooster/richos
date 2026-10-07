# Escalation: Teammates cannot load engine skills: no agent definition grants the Skill tool, so the new audio-transcription and watch-video skills will not reach them by description alone

- id: `esc-20261007T083419Z-2c033f4b`
- raised: 2026-10-07T08:34:19Z
- from: zach-opus-avskills1
- worktree: `/Users/alex/ab/richos-wt/zach-opus-avskills1` (branch `cc/zach-opus-avskills1`)
- head: `aec8754bbc274f7a72894b0591b27f0e9ae5d83b`
- state: **proceeding**
- for: lead

## The question

Who adds Skill to the tools line of every teammate definition (femcboost .claude/agents/*.md, 27 of 28 carry an explicit tools allowlist without Skill), or names the two skills in a skills: preload, so the CEO's goal (every teammate instantly gets the transcription tooling) is actually met?

## What was already tried

Read every femcboost .claude/agents/*.md front matter: 27 definitions have tools: Read, Edit, Write, Bash, Grep, Glob, WebFetch, WebSearch, TaskUpdate, TaskGet, TaskList, SendMessage (pierce: Read, Glob, Grep, Bash; reed without Task tools); none lists Skill and none has a skills: field. Only kai.md has no tools line and so inherits every tool. My own session (zach) has no Skill tool and no available-skills list, although my definition tells me to use the svelte-code-writer skill. The brief premise that the description makes a teammate load the skill holds only for the main session and kai.

## Proceeding meanwhile

Building both skills and their scripts in richos/engine/skills as briefed, with the absolute script paths stated so a brief can also name them directly. Not editing agent definitions (outside the brief, Dean's domain).

## How this reaches the lead

This file is the RECORD, not the delivery. The escalation was written to the
engine escalation ledger at `/Users/alex/.claude/state/escalations.jsonl` as `esc-20261007T083419Z-2c033f4b`, which the
lead's session reads at session start and at every turn end WITHOUT this branch
being merged. If this file is never landed, the escalation still arrives.

Close it with:

    escalate.sh ack esc-20261007T083419Z-2c033f4b --disposition "<what you decided or did>"
