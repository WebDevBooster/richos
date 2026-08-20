---
name: live-app-assessment
description: Workflow for live human visual assessment of implemented app experiences on staging. Use when an advisory agent needs to judge an existing screen, flow, interaction, or gamification surface based on how it actually feels and behaves in the browser, not from code review or screenshots.
---

# Live App Assessment

Use this skill with `playwright-cli` when the task is to assess an implemented app experience the way a human would actually encounter it.

This skill is not QA. It does not turn the agent into a release gate, bug triager, or formal verifier. It enforces one narrower rule: if you are making claims about the actual rendered experience, inspect the real interface live first.

Pair this skill with the expertise of your identity to create a judgment lens for your assessment.

## Use This Skill When

- reviewing an existing primary-user workflow
- judging friction, salience, pacing, hierarchy, clarity, trust, annoyance, motivation, or polish in an implemented product surface
- assessing whether a real screen or flow feels strong enough for its intended users
- comparing the rendered experience against the expectations of a specific persona or role

## Do Not Use This Skill For

- pure code review
- strategy or ideation with no implemented surface
- automated test authoring
- screenshot-only review
- formal QA signoff

## Non-Negotiables

- Use a headed browser on staging for claims about the actual implemented experience
- Use `playwright-cli` for live inspection. Keep the browser open and interact with the real interface
- Move at human pace. Follow visible affordances instead of jumping through hidden shortcuts or machine-speed actions
- Do not treat source code, DOM inspection, local builds, screenshots, or recordings as substitutes for live assessment
- Do not take screenshots first and inspect them later as the primary review method
- Screenshots and recordings are supporting evidence only after something has already been seen live
- Use one window only unless real two-user interaction is part of the task
- Match the viewport to the real user context
- If a point was not visually checked live, label it accordingly

## Viewport Rules

- End-user-facing flows: start on an iPhone-sized mobile viewport
- Internal/operator-facing flows: desktop can be the starting point when that reflects the real workflow
- Shared surfaces or uncertainty: start mobile-first, then expand if needed

## Verification Labels

Use these labels plainly when the distinction matters:

- `Verified visually on staging`
- `Hypothesis from code/local review`
- `Not verified`

Do not present the second or third category as product truth.

## Workflow

1. Decide whether the task is about an implemented surface or only a concept.
2. If it is implemented and you are assessing experience, open staging in a headed browser with `playwright-cli`.
3. Set the viewport to match the real user context.
4. Move through the flow live at normal human pace and note the first-glance reaction before over-analyzing.
5. Capture the main friction, confusion, drop in trust, or strength observed in the live experience.
6. Only after the visual pass, inspect code or docs if needed to explain what you saw.
7. Keep verified observations separate from hypotheses and recommendations.

## If Live Assessment Is Blocked

Say that visual assessment is blocked and do not pretend screenshots, code, or local builds are equivalent.

You may still give framework-based advice if the user wants it, but label it as `Hypothesis from code/local review` or `Not verified`.

## Output Guidance

For any substantive product assessment:

- state the verification basis near the top
- separate verified observations from inferences
- keep the domain judgment in the paired domain skill, not in this workflow skill
