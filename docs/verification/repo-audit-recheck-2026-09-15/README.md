# Audit recheck evidence

These are original CI runner receipts, retained without rewriting their commit
IDs or verdicts. See [the verification report](../repo-audit-fixes-2026-09-15.md)
for fixes, targeted test results and limits.

- `targeted/`: full test output for the by-reference, dispatcher and dialect
  fixes, run before their respective merges. The fix commits and counts are
  recorded in the verification report. It also includes the complete workspace
  specification retry output at `9885955f`.
- `inventory.tsv`: the complete 141-unit inventory.
- `initial/`: the full run at `db92ef8a`, including its six failures and three
  timeouts. This run did not pass.
- `claim-census/`: the isolated three-unit rerun at `5712d56b`, all passed.
- `dependencies/`: the three-unit dependency rerun at `ba709363`, all passed.
- `workspace-retries/`: both full workspace campaigns at `9885955f`, all passed.
- `witness/`: the three affected units at `fb94f088`, all passed.
- `isolated-retries/`: the demo rerun with an isolated temporary directory.

These groups cover different revisions. They must not be combined into a
receipt claiming that one full run at the final revision passed.
