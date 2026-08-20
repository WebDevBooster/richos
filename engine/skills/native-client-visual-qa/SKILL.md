---
name: native-client-visual-qa
description: Use when the functional QA role or another QA agent audits native client app visual quality, Android/iOS parity, simulator/emulator UX, screen-by-screen polish, interaction feel, layout, typography, spacing, color, navigation, loading, empty/error states, or whether a platform is ready to involve the design gatekeeper. Applies only to client native apps under `${NATIVE_ANDROID_ROOT}`/`${NATIVE_IOS_ROOT}`, not any separate web/PWA surface.
---

# Native Client Visual QA

Use this for native-client visual QA.

<!-- TODO (adopter): state your surface split here if your product has more than
     one user-facing surface (e.g. "native apps are for end-users; a separate
     web/PWA surface is for a different user type"). Delete this note if you
     have a single native surface and no separate web/PWA surface to distinguish. -->

This skill adds native client QA. It does not replace any separate web/PWA QA your product needs — a distinct surface still requires its own QA path (headed-browser or otherwise).

## Authority Split

- The **functional QA role** owns human-perceived visual and functional UX quality when assigned to native client QA.
- The **device QA role** owns mobile data accuracy, health-store behavior, install/update, push, TestFlight/Play-track and physical-device coverage.
- The **design gatekeeper** owns design quality signoff, but only after the functional QA role says the native client surface is close enough to be worth the gatekeeper's time.
- <!-- TODO (adopter): name which platform (if any) is your current quality reference for native client UI, e.g. "Android is the reference platform until iOS reaches parity." Delete this bullet if neither platform is a fixed reference. --> {reference platform} is the current quality standard for native client UI unless the orchestrator names a newer approved reference.

## Simulator/Emulator First

Physical device testing is not allowed as a substitute for basic quality.

Before physical-device QA:
1. Android emulator install-fresh (or your equivalent fresh-install verification) must pass.
2. iOS Simulator install-fresh (or your equivalent) must pass.
3. Client data-render checks must pass for the fields being compared, if you've adopted that tier.
4. The functional QA role must complete the screen-by-screen visual pass without obvious blockers.

Only then should the device QA role move to physical devices for platform behavior.

## Required Preflight

1. Read your canonical surface/topology doc, if your product has more than one client surface (native vs. web/PWA, or multiple apps sharing a backend).
   <!-- TODO (adopter): name that doc here, if one exists. -->
2. Get the expected commit SHA from the orchestrator.
3. For Android, run or require a successful fresh-install verification before trusting the emulator. If you've adopted the kit's advanced "identity-or-refuse" tier, `reference/advanced-tier/android-install-fresh.sh` (gated by `ENABLE_QA_INSTALL_FRESH_GATE` in `orchestration.config`) IS this step — use it. Otherwise, define and cite your own equivalent fresh-install-and-verify procedure here.
4. For iOS, same pattern using `reference/advanced-tier/ios-install-fresh.sh` if adopted, or your own equivalent otherwise.
5. Use your project's scripted login helper(s) for test-account login. Do not hand-type credentials.
   <!-- TODO (adopter): name your login script(s) here, if any exist. -->
6. If either install-fresh (or equivalent) fails, stop. Report the failing layer and do not audit pixels from that artifact.

## Visual Parity Pass

For each in-scope screen:
1. Capture current Android and iOS screenshots from the same user, same seed, same SHA and same logical screen state.
2. Put them side by side.
3. Inspect live, not only screenshots.
4. Compare information architecture, composition order, top/bottom safe areas, navigation, scrolling, card density, typography hierarchy, spacing, color, icons, component states and copy.
5. Exercise common user actions: tap, back, tab switching, scroll, keyboard entry, loading, empty state, error state and retry.
6. Mark every finding with severity and user impact.

Do not mark a screen PASS from source inspection, nav title presence, fixture rendering or a single screenshot.

## Audit Format — MANDATORY per-dimension prose comparison

Every audit MUST include:

- Expected SHA and install-fresh result for each platform.
- Device names and OS versions.
- Screens audited (with a row for every screen in scope; deferred captures are explicit, not silent).
- Side-by-side evidence path for each screen.

**Per-screen section — mandatory table format. No shortcuts. No `✓`. No "matches." No "clean." No "parity looks good."**

For every screen, the audit MUST include a per-dimension comparison table with THREE required columns per row:

```
### <Screen name>

| Dimension | Android observation | iOS observation | Mismatch |
|-----------|---------------------|-----------------|----------|
| Header typography | <specific pixel-level observation> | <specific pixel-level observation> | yes/no + description |
| Top padding / safe-area | <specific> | <specific> | yes/no + description |
| Hero element position | <specific> | <specific> | yes/no + description |
| Card density / spacing | <specific> | <specific> | yes/no + description |
| Tab bar state | <specific> | <specific> | yes/no + description |
| <other dimensions relevant to this screen> | <specific> | <specific> | yes/no |

**Screen verdict:** PASS if every row's Mismatch = no. FAIL otherwise, with the specific row(s) causing failure called out in prose.
```

### Rules for the observation rows

- "Specific" means pixel-level and describable in words. "Number is large" is NOT specific. "45pt white DMSans-Black, horizontally centered at x=135 in design coords, vertically positioned ABOVE the dial's top arc boundary rather than inside the dome interior" IS specific.
- You may NOT write `✓`, `matches`, `clean`, `parity`, `same`, or any other summary verdict word in the Android or iOS observation columns. Those columns are DESCRIPTIONS of what is rendered, not judgments of whether they match.
- The Mismatch column is binary (`yes` or `no`) plus a short description. It is derived from the two observation columns — you cannot assert `no` if the two observations describe different things.
- If a dimension is complex (multiple sub-observations), split it into multiple rows. Do not collapse.
- If iOS evidence is deferred/missing for a screen, still write the Android observation row and mark the iOS column `deferred capture — <specific reason>`. Do not pretend an unexamined iOS screen is a PASS.

### Screen-level verdict

- **PASS** only if every row's Mismatch = `no`.
- **FAIL** if any row's Mismatch = `yes`. List the failing rows by name in a "Blockers for this screen" sentence directly below the table.
- The QA agent is NOT allowed to override a `yes` Mismatch with a "but it's close enough" claim. If the iOS observation differs from the Android observation, it is a FAIL unless the audit explicitly cites a justified platform deviation (e.g., "iOS Dynamic Island adds 8px header offset — intentional platform-native difference, not a port gap").

### Audit-level outputs (still required)

- Findings grouped by P0/P1/P2/P3 (derived from the per-screen FAIL rows).
- **"Ready for the design gatekeeper: yes/no" — must cite the per-screen PASS/FAIL count.** "Ready for the design gatekeeper: yes" is valid only if every audited screen has verdict PASS. One screen FAIL = "Ready for the design gatekeeper: no" with blocker list.
- If the answer is "no," list each failing screen + the row(s) that failed + a one-line fix scope.

### Why the format is mandatory

Previous audits shipped "✓ whitespace clean" rows on screens where iOS rendered the hero element outside the dial interior. The checkmark format allowed the comparison to happen silently at look-time (or not at all) while the write-time output only showed the verdict. The three-column format forces the comparison INTO the written evidence. If the two observation columns describe different things, the QA cannot write "no" in the Mismatch column; if they describe the same thing, the Mismatch is `no` and the row defends itself.

Write the audit markdown to `qa-audits/<descriptive-name>-YYYY-MM-DD.md`. Authored work product requested via this skill — not a documentation file. Use the Write tool directly. Bash heredoc fallback works if anything self-vetoes.
