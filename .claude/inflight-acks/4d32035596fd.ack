sha: 4d32035596fd4fe4f467c698e99c9a3a4a8d8d81
impact: none
detail: My new guard is a Stop hook under engine/scripts/hooks/ plus registrations in engine/hooks/hooks.json, engine/scripts/hooks/install.sh and the guard-count tripwire in contract-integrity-probe.sh. The merge deleted app/acp-adapter/ and repointed 52 files under app/ — I touch nothing under app/ and my brief forbids it, so no file of mine is in that changeset and no assumption of mine breaks. I stay based on a2737bd and do not rebase; the lead resolves the three-way merge with the two other Zach branches touching hooks.json/install.sh/the probe.
paths: engine/hooks/hooks.json engine/scripts/hooks/install.sh engine/scripts/hooks/contract-integrity-probe.sh
worktree: /Users/alex/ab/richos-wt/zach-p1
written: 2026-08-31T22:03:36Z
