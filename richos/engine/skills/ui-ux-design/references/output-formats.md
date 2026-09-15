# Output Formats

Use these structures to keep design output clear and implementation-ready.

## UX Audit

```md
## UX Audit

Context
- User:
- Surface:
- Primary task:
- Device context:

First-glance verdict
- What feels off immediately:
- What feels strong immediately:

Diagnosis
- One-sentence summary of the main UX problem.

Comparative critique
- Best comparison product:
- Where the current product falls short:

Findings
1. [Severity] Finding title
   File or route:
   Why it fails:
   Underlying design failure:
   Change required:

2. [Severity] Finding title
   File or route:
   Why it fails:
   Underlying design failure:
   Change required:

Recommended direction
- One clear recommendation for the overall interaction model.

Top priorities
- Fix first:
- Remove outright:
- Verify visually:

State requirements
- Empty:
- Loading:
- Error:
- Offline:
- Warning or over-limit:

Implementation handoff
- For the designer:
- For the front-end engineer:
- For the copywriter:
- For QA:
```

## New Feature Flow Spec

```md
## Flow Spec

User and goal
- User:
- Goal:
- Success definition:

Flow
1. Entry point
2. Main interaction
3. Confirmation or next state
4. Recovery path

Screen rules
- Primary action:
- Secondary actions:
- Information hierarchy:
- Required states:

Constraints
- Mobile:
- Accessibility:
- Design system:
- White-label:

Recommendation
- The one direction to implement and why.
```

## Redesign Brief

```md
## Redesign Brief

First-glance verdict
- What makes the current experience feel second-rate:

Problem
- What is broken and who feels it?

Target outcome
- What should feel faster, clearer or more trustworthy?

Comparative benchmark
- Which respected product sets the bar for this moment and why:

Proposed changes
- Layout:
- Hierarchy:
- Interaction:
- Feedback and states:

Risks
- What could regress if this is implemented badly?

Acceptance checks
- 3 to 5 observable checks QA can verify.
```
