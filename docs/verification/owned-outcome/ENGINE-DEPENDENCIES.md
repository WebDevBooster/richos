# Engine dependency boundary after the external review

The external review was right: the first adoption branch was an unconditional
bypass of the CEO dispatch guard. Allowing unrelated work did not justify allowing
a dispatch that explicitly declared missing CEO authority. It also did not justify
silencing an already nonblocking reminder or returning a clear status for pending
decisions.

## Current mechanism

Adoption is explicit in `.claude/owned-work.json` with integer `version: 1`, boolean
`enabled: true` and `decision_policy: "dependency"`. Missing, disabled or incorrectly
typed values do not select the new policy. There is no compatibility fallback to
the previous root dotfile because this integration has not been installed.

The adopted Agent guard reads the same authoritative CEO item records as the
existing engine, through `.ceo-todos`, `CEO_TODOS_REPOS` and the existing parser. It
has no per-session question quota. An independent dispatch proceeds without an ask
receipt or a deferral log entry.

A dependent dispatch names the prepared item in its execution brief:

```
depends-on-ceo: 1.1
```

Multiple IDs may be comma-separated. A named item that is still `READY-FOR-CEO`
blocks that dependent dispatch. Unknown, ambiguous, empty or unprepared references
cannot establish cleared authority and also block. An unreadable record cannot
clear a declared dependency. Routine repair of the record remains Rich's work.

The existing ask ledger is deliberately not supplied to this dependency check.
It records that a question was asked, not the answer, its scope or approval to
proceed. `ceo-todos-deferred:` cannot override a declared dependency. Once the CEO
actually answers, Rich incorporates that ruling, reconciles the pending record and
rebriefs within the granted authority. Neither disappearance of an item nor a
changed marker is itself proof of authorization. Existing permission, publication
and spending boundaries still apply.

The checker also recognizes a bounded set of explicit dependency declarations,
including the review's exact counterexample: “He has NOT answered it” combined with
a statement that this dispatch depends on that answer. Mentioning an unrelated
unanswered question does not create a dependency. It recognizes direct phrases such as “cannot
proceed without the CEO approval” and preserves explicit negation such as “does not
depend on the CEO answer.” A marker is not required to stop those known declarations.

SessionStart and Stop again show a named pending decision without holding unrelated
work. Stop reminders retain the existing deduplication behavior. In adopted mode
they consult all pending prepared items, including those already asked. The status
CLI returns OPEN/exit 1 while those items remain pending and exit 0 only when no
prepared items remain. Exit 1 is pending state, not command failure and not a demand
to block independent work.

The helper is included in the installer's existing integrity sidecar list, so a
changed dependency implementation is not invisible to that integrity mechanism.

## Exact limits

This is a dispatch boundary for declared dependencies and recognizable explicit
missing-authority statements. It does not mechanically classify all natural
language, inspect every Bash command or establish that an answer is authentic and
sufficient. Quoted examples and more complicated negation can need a clearer
execution brief. No claim of a complete prose classifier is made.

Semantic interpretation, checking the actual CEO answer and choosing a legitimate
business escalation remain responsibilities of Rich and the independent outcome
reviewer. This engine patch does not add another model classifier or another
framework. The native adapter and question-review changes are documented and
verified separately by the lead.

## Verification

The direct CEO suite passes 71 cases. Added cases demonstrate independent dispatch,
pending dependency refusal, refusal after an ask and a deferral, the exact review
counterexample, unknown/empty references, persistent pending status/reminders,
reminder deduplication, explicit independence, unrelated unanswered questions and nine invalid config variants.
The suite also pins the new helper in the installer's integrity sidecar list.

The full suite invokes behavioral mutations. New mutants remove config field checks,
bypass declared dependencies, ignore explicit missing authority, misread negation,
silence the adopted reminder and use an ask receipt to clear pending state. Each
must fail a named case. Final counts and the process result are recorded after that
run completes rather than inferred from the direct suite.

Final frozen-source verification completed with process exit 0:
`bash engine/scripts/hooks/ceo-asks.test.sh` passed **71/71 cases** and its invoked
mutation harness killed **24/24 mutants**, each at the required named case. Log:
`/tmp/richos-ceo-dependency-r3-full.log`. The separate direct run also passed 71/71:
`/tmp/richos-ceo-dependency-r3-tests.log`. Earlier r2 runs overlapped corrections and
were stopped; they are not used as final evidence. `git diff --check` passed.
