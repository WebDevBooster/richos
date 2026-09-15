# Team profile stubs (HR records)

`/team/` is the **HR record** — one plain-markdown profile per teammate (no
frontmatter; that lives only in `.claude/agents/<name>.md`).

The four working meta-roles already have real profiles here:
`team/dean.md`, `team/clark.md`, `team/reed.md`, `team/frank.md`.

Every other teammate is created from a role template. Because the HR-profile
**shape is identical across all roles**, this directory ships a single skeleton —
`PROFILE-TEMPLATE.md` — rather than 16 near-duplicate stubs. When Dean instantiates
an agent template from `.claude/agents/templates/`, he:

1. Copies `PROFILE-TEMPLATE.md` to `/team/<name>.md`.
2. Fills it from the same persona and research used for the agent definition.
3. Adds the new teammate to `/team/ROSTER.md` and `CLAUDE.md`'s team directory.

The agent-definition templates in `.claude/agents/templates/` (and their README)
are the authoritative catalog of available roles and the persona→template mapping.
