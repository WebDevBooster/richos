# UX Heuristics

Apply these heuristics when auditing or designing your product.

These checks support judgment. They do not replace it.

## 0. First-glance quality

- Does the screen feel intentional in the first 5 seconds?
- Is there anything immediately amateur, noisy, filler-heavy or low-trust?
- Does the page tell one coherent story or look like unrelated widgets stacked together?

## 1. Time-to-action

- Can the user identify the main action in under 2 seconds?
- Can a repeat user complete the core task with minimal thought?
- Are there avoidable taps, scrolls or mode switches?

## 2. Hierarchy and focus

- Is the most important number or action visually dominant?
- Is secondary information truly secondary?
- Does the screen try to explain too much at once?

## 3. Mobile ergonomics

- Is the main action reachable one-handed?
- Are tap targets at least 44x44px?
- Does the screen depend on long precision scrolling, tiny controls or dense horizontal layouts?

## 4. State coverage

Check each major flow for:
- Empty
- Loading
- Success
- Error
- Offline
- Permission denied
- Over-limit or warning
- Recoverable interruption

Missing states are design bugs.

## 5. Tone and respect

- Does the UI sound like a serious professional tool?
- Does it avoid shaming, cuteness and therapy-speak?
- Does feedback respect the user's intelligence?

## 6. System fit

- Can the recommendation be built within your design system and the implementation constraints documented in `docs/design-system/`?
- Does it preserve white-label flexibility?
- Does it reuse existing patterns where that helps consistency?

## 7. Accessibility

- Is the structure semantic?
- Is contrast sufficient in all states?
- Are warnings conveyed by more than color?
- Can the flow be completed with keyboard and assistive tech?

## 8. Behavioral design

- Does the screen increase adherence without feeling manipulative?
- Is friction reserved for genuinely risky actions?
- Do warning states create clarity, not shame?

## 9. Power-user efficiency

For power-user / operator surfaces:
- Does the screen make anomalies and priorities obvious?
- Can the power user act without drilling into unnecessary detail?
- Does the layout separate monitoring from action?

## 10. Trust

- Does the experience feel premium enough for a paid product?
- Does it look reliable and discreet?
- Would the user trust it with repeated daily use?

## 11. Taste and restraint

- Has anything been added just because space existed?
- Would removing a card, metric or label improve the page?
- Does the UI look designed by a person with judgment or assembled from requirements?
