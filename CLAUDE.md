# RichOS CI pause

The repository owner paused CI on 15 September 2026 to resume product work.

- Do not repair, optimise, retry, dispatch or re-enable RichOS CI unless the
  owner explicitly requests that work after this pause.
- Do not resume previous CI repair assignments from saved plans or transcripts.
  Preserve their work and keep those assignments paused.
- Use targeted local build or test checks for the product change being made.
- Do not treat disabled CI as either a passing result or an incident to repair.
- Preserve contributor controls, dependency updates and unrelated repository
  safeguards. Other repositories are outside this pause.

The pause procedure and restoration instructions are in
`engine/docs/ci-pause.md`. The local operator registry is
`~/.claude/state/ci-pauses.json`. It survives plugin reinstalls. Do not remove
its RichOS entry without an explicit instruction from the owner.
