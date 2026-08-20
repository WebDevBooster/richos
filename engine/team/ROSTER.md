# Team Roster

The single HR-record list of the team. Keep this in sync with `CLAUDE.md`'s team
directory (that copy is the orchestrator's runtime routing reference; this one is
the HR record). Do NOT duplicate the roster inside any individual agent's own
definition — reference this file by pointer instead.

## Working meta-roles (ship with the kit, spawnable out of the box)

| Name | Role | Slug | Model |
|---|---|---|---|
| Dean | HR Director — hires/creates teammates, re-authors role templates | `dean` | sonnet |
| Clark | Senior Researcher — role/skill/domain research | `clark` | sonnet |
| Reed | Source-Reading & Knowledge-Extraction Specialist — durable committed briefs | `reed` | sonnet |
| Frank | Expert Advisor / Devil's Advocate — stress-tests decisions | `frank` | opus |

## Your domain team (fill in as Dean instantiates role templates)

<!-- TODO (adopter): as Dean turns the skeletons in .claude/agents/templates/ into
     real, named teammates for your domain, add each one here. Example row shape:

     | Name | Role | Owns | Slug | Model |
     |------|------|------|------|-------|
     | ...  | Backend Engineer | server/data layer | ... | sonnet |

     Keep this table and CLAUDE.md's team directory in lockstep. -->
