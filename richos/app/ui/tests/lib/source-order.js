// Whether the startup sequence in main.js asks the setup question before the memory one.
// Hunt part 2, R57: the old check only proved both helper names existed; it never compared
// where they are called, so a reversed order passed. The startup call site is
// `const X = maybeAskAboutSetup(); ... !X && maybeAskAboutMemory()` — the memory question is
// gated on the setup answer, which is only possible when setup is called first.
"use strict";

const STARTUP_ORDER = /const\s+(\w+)\s*=\s*maybeAskAboutSetup\(\)\s*;[\s\S]*?!\1\s*&&\s*maybeAskAboutMemory\(\)/;

function setupAskedBeforeMemory(src) {
  return STARTUP_ORDER.test(src);
}

module.exports = { setupAskedBeforeMemory };
