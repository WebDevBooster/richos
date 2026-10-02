/**
 * Fixture test for the "Include above 'Branched from' content" checkbox
 * (markdown.js `conversationToMarkdown(conversation, options)`).
 *
 * Run: node engine/tools/gpt-exporter/export/__tests__/branch-trim.test.mjs
 *
 * markdown.js has no browser globals (no chrome.*, no document, no window),
 * so it can be driven directly from Node with plain fixture objects that
 * mirror the real ChatGPT conversation/mapping shape.
 */

import assert from 'node:assert/strict';
import { conversationToMarkdown } from '../markdown.js';
import { buildBranchedConversation, buildNonBranchedConversation } from './branch-trim.fixture.mjs';

let failures = 0;

function check(name, fn) {
    try {
        fn();
        console.log(`  ok - ${name}`);
    } catch (err) {
        failures += 1;
        console.error(`  FAIL - ${name}`);
        console.error(`    ${err.message}`);
    }
}

console.log('branch-trim fixture test');

// (a) checked (includeAboveBranchedFrom: true) == current/default output
check('checked output is byte-identical to no-options (default) output', () => {
    const conv = buildBranchedConversation();
    const withOptionTrue = conversationToMarkdown(conv, { includeAboveBranchedFrom: true }).content;
    const withNoOptions = conversationToMarkdown(conv).content;
    assert.equal(withOptionTrue, withNoOptions);
});

check('checked output retains all pre-branch and post-branch content', () => {
    const conv = buildBranchedConversation();
    const { content } = conversationToMarkdown(conv, { includeAboveBranchedFrom: true });
    assert.match(content, /Pre-branch question one\./);
    assert.match(content, /Pre-branch answer one\./);
    assert.match(content, /Branched from \[\[RichOS_Market_Fit_parent-c\|RichOS Market Fit\]\]/);
    assert.match(content, /Post-branch question one\./);
    assert.match(content, /Post-branch answer one\./);
});

// (b) unchecked output matches the expected trimmed shape
//
// Rather than hand-authoring the frontmatter block (fragile against
// timestamp/id formatting), derive the expected trimmed markdown from the
// verified-correct "checked" output: frontmatter + blank + heading are kept
// byte-for-byte, and everything between the heading and the divider's
// leading "---" is removed. That is exactly the manual trim shape
// (frontmatter, blank, heading, blank, ---, blank, Branched from ..., blank,
// ---, blank, content) and exactly what conversationToMarkdown must produce
// with the checkbox unchecked.
check('unchecked output matches the manual trim shape exactly', () => {
    const conv = buildBranchedConversation();
    const checkedContent = conversationToMarkdown(conv, { includeAboveBranchedFrom: true }).content;
    const uncheckedContent = conversationToMarkdown(conv, { includeAboveBranchedFrom: false }).content;

    const headingMarker = '\n\n# Loro features · RichOS Market Fit\n\n';
    const dividerMarker = '---\n\nBranched from [[RichOS_Market_Fit_parent-c|RichOS Market Fit]]\n\n---\n\n';

    const headingIdx = checkedContent.indexOf(headingMarker);
    const dividerIdx = checkedContent.indexOf(dividerMarker);
    assert.ok(headingIdx !== -1, 'heading marker must be present in checked output');
    assert.ok(dividerIdx !== -1, 'divider marker must be present in checked output');

    const frontmatterAndHeading = checkedContent.slice(0, headingIdx + headingMarker.length);
    const fromDividerOnward = checkedContent.slice(dividerIdx);
    const expected = frontmatterAndHeading + fromDividerOnward;

    assert.equal(uncheckedContent, expected);
});

check('unchecked output removes pre-branch content entirely', () => {
    const conv = buildBranchedConversation();
    const { content } = conversationToMarkdown(conv, { includeAboveBranchedFrom: false });
    assert.doesNotMatch(content, /Pre-branch question one\./);
    assert.doesNotMatch(content, /Pre-branch answer one\./);
});

check('unchecked output preserves heading directly followed by the divider (manual trim shape)', () => {
    const conv = buildBranchedConversation();
    const { content } = conversationToMarkdown(conv, { includeAboveBranchedFrom: false });
    assert.match(
        content,
        /# Loro features · RichOS Market Fit\n\n---\n\nBranched from \[\[RichOS_Market_Fit_parent-c\|RichOS Market Fit\]\]\n\n---\n\n> \[!me:\]/
    );
});

// (c) non-branched chat is identical in both modes
check('non-branched conversation is identical whether checked or unchecked', () => {
    const conv1 = buildNonBranchedConversation();
    const conv2 = buildNonBranchedConversation();
    const checked = conversationToMarkdown(conv1, { includeAboveBranchedFrom: true }).content;
    const unchecked = conversationToMarkdown(conv2, { includeAboveBranchedFrom: false }).content;
    assert.equal(checked, unchecked);
    assert.match(checked, /A regular question, no branch\./);
    assert.match(checked, /A regular answer, no branch\./);
});

if (failures > 0) {
    console.error(`\n${failures} check(s) FAILED`);
    process.exit(1);
} else {
    console.log('\nAll checks passed');
    process.exit(0);
}
