"use strict";
// THE ALIVENESS MARK, at every point of its animation, in both themes.
//
// Arithmetic from the shipping checker rather than re-typed: `app/ui/tests/lib/contrast.js`,
// the same functions `app/ui/tests/contrast.js` runs against the real DOM.
//
// WHAT IT IS FOR. The mark is a NON-TEXT UI INDICATOR and owes 3:1 in both themes. Until
// 2026-09-06 `.tl-pulse` was `--accent` breathing between 0.2 and 0.7 opacity, and the
// numbers below are why that had to change: at its dimmest it was 1.40:1 dark and 1.22:1
// light, and in LIGHT it never cleared the floor at any point of its cycle. The `--live-mark`
// rows are the replacement, at full opacity in both themes.
const path = require("path");
const C = require(path.resolve(__dirname, "..", "..", "..", "app", "ui", "tests", "lib", "contrast.js"));

const GROUND = { dark: { r: 12, g: 19, b: 34, a: 1 }, light: { r: 234, g: 230, b: 221, a: 1 } };
// `--accent` as `.tl-pulse` used it (the OLD mark), and `--live-mark` (the new one).
const OLD_MARK = { dark: { r: 194, g: 163, b: 92 }, light: { r: 156, g: 124, b: 52 } };
const NEW_MARK = { dark: { r: 194, g: 163, b: 92 }, light: { r: 113, g: 87, b: 21 } };
const QUIET_MARK = { dark: { r: 224, g: 154, b: 85 }, light: { r: 140, g: 74, b: 27 } };

function row(label, theme, rgb, op) {
  const bg = GROUND[theme];
  const solid = C.compositeOver(Object.assign({}, rgb, { a: op }), bg);
  const ratio = C.contrastRatio(solid, bg);
  console.log(
    label.padEnd(30),
    theme.padEnd(6),
    ("opacity " + op).padEnd(13),
    C.hex(solid),
    "->",
    (ratio.toFixed(2) + ":1").padStart(8),
    ratio >= 3 ? "PASS" : "FAIL (3:1 non-text floor)"
  );
}

console.log("--- OLD .tl-pulse: --accent, opacity animated 0.2 -> 0.7 (0.7 pinned under reduced motion)");
for (const theme of ["dark", "light"]) for (const op of [0.2, 0.45, 0.55, 0.7]) row("old .tl-pulse (--accent)", theme, OLD_MARK[theme], op);
console.log("\n--- NEW mark: --live-mark, FULL opacity, size animated instead");
for (const theme of ["dark", "light"]) row("--live-mark", theme, NEW_MARK[theme], 1);
console.log("\n--- NEW mark, quiet state: --attention, full opacity");
for (const theme of ["dark", "light"]) row("--attention", theme, QUIET_MARK[theme], 1);
