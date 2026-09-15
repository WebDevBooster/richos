# Actual Claude canary: administrator launch boundary

The first actual CLI acceptance attempt from candidate `4a1ea770df1f4059d48ebdd4cace1cba27d14fcc`
failed before fixture allocation or model execution. The protected receipt is
`/Library/Application Support/RichOS/workspace-broker/acceptance-runs/claude-canary-60c97a84dbe44e629ec60c276ea2b15f/receipt.jsonl`.

The failure was `normal owner login unavailable; no credentials copied or substituted`.
The administrator supervisor dropped its subprocess UID/GID and supplied the
owner's HOME, USER and LOGNAME, but that did not restore the owner's macOS
bootstrap context. This is an acceptance-launcher defect, not a passing or
failing result for the workspace lifecycle itself.

A read-only comparison on the same host established:

| Invocation context | Exit | loggedIn | authMethod |
| --- | --- | --- | --- |
| Existing owner process | 0 | true | claude.ai |
| Administrator subprocess with UID 501, GID 20 and owner environment | 1 | false | none |
| Administrator launchctl asuser 501, then sudo -u alex | 0 | true | claude.ai |

Only the authentication status fields were inspected. Credentials were neither
read nor copied. No test namespace, model session or production configuration
was created by the failed attempt. The test launcher must enter the owner's
bootstrap context as well as dropping privileges, preserve its explicitly
isolated environment and identify the real Claude process before a rerun can
count as lifecycle evidence. Production activation remains pending.
