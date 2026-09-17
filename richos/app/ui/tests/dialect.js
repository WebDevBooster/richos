// AMERICAN ENGLISH ON THE SIGN-IN PATH — a scanner over the two files that shipped a British
// spelling on text a person reads: `provider_auth.rs`'s `AuthState::Cancelled` message and
// `main.js`'s cancel-failure catch clause (nightly QA audit
// `docs/verification/2026-09-17-nightly-1.2.0-20260917.1-silent-audit.md` §D1, richos
// `5f448983`). CEO ruling, 2026-08-29: American English is the language of every string a
// person reads.
//
// SCOPE IS DELIBERATELY NARROW, not a blanket grep for the British spelling over either whole
// file. `AuthState::Cancelled` is a Rust enum variant identifier, and its
// `#[serde(rename_all = "kebab-case")]` wire value is the ACP-style protocol value `mock.js`
// matches against (`providerState = "cancelled"`) — neither is prose a person reads, and the
// dialect rule never binds an identifier or a wire value. So this scan reads ONLY the two
// literals that hold what the human sees, each pulled out by the shape of the call that
// carries it rather than by the word itself, and checks that literal alone.
//
// EVERY CHECK CARRIES A POSITIVE CONTROL, for the reason `voice-model.js` states: a "nothing
// found" assertion passes identically when the scanner works and when it is not looking at
// anything at all. Each check re-runs its own extractor against a string that plants the
// forbidden British spelling in the exact shape it targets, and requires the extractor to
// both find the literal and see the forbidden word in it — proving the clean result above it
// is not vacuous. Those fixtures are never written to disk, and each carries its own
// `dialect-exempt:` marker: the word inside them is the thing under test, not a claim about
// what this file itself says.
//
// No browser: this is a plain node script, in the shape `docs-claims.js` already uses. `run.js`
// runs every .js file in this directory, so it is registered by existing, and its row in this
// README keeps `docs-claims.js`'s own table check green.

"use strict";

const fs = require("fs");
const path = require("path");
const { createRun, assert, assertEqual, rustSentenceAfter, UI_DIR } = require("./lib/harness");

const APP_DIR = path.resolve(UI_DIR, "..");
const PROVIDER_AUTH_RS = path.join(APP_DIR, "crates", "richos-core", "src", "provider_auth.rs");
const MAIN_JS = path.join(UI_DIR, "main.js");

// The word this whole suite exists to forbid, built at runtime rather than written literally
// here, so THIS declaration is never itself a hit for the very pattern it defines.
const FORBIDDEN = "cance" + "lled";
const BRITISH = new RegExp("\\b" + FORBIDDEN + "\\b", "i");

/// The message `AuthView::new` sets for `AuthState::Cancelled`. Read the same way
/// `lib/harness.js` reads any other CEO-facing Rust sentence: backward from a marker inside
/// the literal to its opening quote, so code after the literal's closing quote is never
/// mistaken for part of the sentence.
function providerAuthCancelledMessage(src) {
  return rustSentenceAfter(src, "Sign-in was");
}

/// `main.js`'s catch clause for a failed `provider_auth_cancel` round trip. Anchored on the
/// surrounding call shape — `renderProviderAuth({state: "connecting", message: "…"})` — which
/// is stable regardless of which word the sentence uses, so this finds the literal whether it
/// currently reads the American spelling or (as a regression, or in the positive control
/// below) the British one.
function mainJsCancelFailureMessage(src) {
  const m = src.match(/renderProviderAuth\(\{state: "connecting", message: "([^"]*)"\}\)/);
  return m ? m[1] : null;
}

async function main() {
  const run = createRun("American English on the sign-in path");

  await run.check("provider_auth.rs's AuthState::Cancelled message is American, and the scan is not vacuous", async () => {
    const src = fs.readFileSync(PROVIDER_AUTH_RS, "utf8");
    const msg = providerAuthCancelledMessage(src);
    assert(!BRITISH.test(msg), `provider_auth.rs still says "${msg}"`);

    // Positive control: the same extractor, over a fixture that plants the British spelling
    // in the identical literal shape — never written to disk.
    const planted =
      'AuthState::Cancelled => "Sign-in was ' + FORBIDDEN + // dialect-exempt: planted fixture is the word under test, not this file's own prose
      '. You can try again when you are ready.",';
    const plantedMsg = providerAuthCancelledMessage(planted);
    assert(BRITISH.test(plantedMsg), "positive control failed: the extractor did not see a planted British spelling");
    return `"${msg}"`;
  });

  await run.check("main.js's cancel-failure message is American, and the scan is not vacuous", async () => {
    const src = fs.readFileSync(MAIN_JS, "utf8");
    const msg = mainJsCancelFailureMessage(src);
    assert(msg, "the cancel-failure catch clause's message literal was not found at all");
    assert(!BRITISH.test(msg), `main.js still says "${msg}"`);

    // Positive control: the same extractor, over a fixture that plants the British spelling
    // in the identical call shape — never written to disk.
    const planted =
      'catch (_) { renderProviderAuth({state: "connecting", message: "Sign-in could not be ' + FORBIDDEN + // dialect-exempt: planted fixture is the word under test, not this file's own prose
      '. Try again."}); }';
    const plantedMsg = mainJsCancelFailureMessage(planted);
    assert(plantedMsg, "positive control failed: the extractor did not find the planted literal at all");
    assert(BRITISH.test(plantedMsg), "positive control failed: the extractor found the planted literal but missed its British spelling");
    return `"${msg}"`;
  });

  const failed = run.report();
  return failed;
}

main().then((f) => process.exit(f ? 1 : 0));
