| Event | Hook | Matcher | control | empty | truncated | non-JSON | Verdict | Trace steps |
|---|---|---|---|---|---|---|---|---|
| PreToolUse | `guard-sealed-worktree.sh` | `(all)` | **refuses** | **refuses** | **refuses** | **refuses** | **FAILS CLOSED** | 181 / 43 / 68 / 43 |
| PreToolUse | `guard-worktree-isolation.sh` | `Agent` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 275 / 129 / 129 / 129 |
| PreToolUse | `guard-definition-drift.sh` | `Agent` | passes, speaks | passes, speaks | passes, speaks | passes, speaks | **payload-independent** | 183 / 134 / 133 / 133 |
| PreToolUse | `reader-teammate-hint.sh` | `Agent` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 136 / 126 / 126 / 126 |
| PreToolUse | `verify-agent-prompt.sh` | `Agent` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 219 / 131 / 131 / 131 |
| PreToolUse | `guard-ceo-ask-first.sh` | `Agent` | **refuses** | passes, speaks | passes, speaks | passes, speaks | **FAILS OPEN (proven)** | 303 / 165 / 165 / 165 |
| PreToolUse | `guard-model-ceiling.sh` | `Agent` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 555 / 125 / 125 / 125 |
| PreToolUse | `guard-main-checkout-writes.sh` | `Write\|Edit\|MultiEdit\|NotebookEdit` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 184 / 130 / 130 / 130 |
| PreToolUse | `scan-secrets.sh` | `Write\|Edit\|MultiEdit\|NotebookEdit` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 208 / 134 / 134 / 134 |
| PreToolUse | `guard-publication-writes.sh` | `Write\|Edit\|MultiEdit\|NotebookEdit` | passes, silent | passes, silent | passes, silent | passes, silent | **FAILS OPEN (predicate not evaluated)** | 1379 / 154 / 156 / 156 |
| PreToolUse | `guard-named-persons-writes.sh` | `Write\|Edit\|MultiEdit\|NotebookEdit` | passes, silent | passes, silent | passes, silent | passes, silent | **FAILS OPEN (predicate not evaluated)** | 158 / 82 / 82 / 82 |
| PreToolUse | `guard-dialect.sh` | `Write\|Edit\|MultiEdit\|NotebookEdit` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 425 / 132 / 132 / 132 |
| PreToolUse | `guard-resume-isolation.sh` | `SendMessage` | **refuses** | **refuses** | **refuses** | **refuses** | **FAILS CLOSED** | 252 / 154 / 154 / 154 |
| PreToolUse | `guard-ceo-ruled-ask.sh` | `AskUserQuestion` | passes, silent | passes, speaks | passes, speaks | passes, speaks | **FAILS OPEN (predicate not evaluated)** | 253 / 215 / 215 / 215 |
| PreToolUse | `guard-interactive-prompt.sh` | `Bash` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 110 / 98 / 98 / 98 |
| PreToolUse | `guard-bash-main-writes.sh` | `Bash` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 135 / 127 / 127 / 127 |
| PreToolUse | `guard-inflight-notify.sh` | `Bash` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 119 / 119 / 119 / 119 |
| PreToolUse | `guard-worktree-removal.sh` | `Bash` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 127 / 99 / 99 / 99 |
| PreToolUse | `guard-publication-commits.sh` | `Bash` | passes, silent | passes, silent | passes, silent | passes, silent | **FAILS OPEN (predicate not evaluated)** | 1356 / 167 / 169 / 169 |
| PreToolUse | `guard-named-persons-commands.sh` | `Bash` | passes, silent | passes, silent | passes, silent | passes, silent | **FAILS OPEN (predicate not evaluated)** | 156 / 89 / 89 / 89 |
| PreToolUse | `guard-ceo-todos-commits.sh` | `Bash` | passes, silent | passes, silent | passes, silent | passes, silent | **FAILS OPEN (predicate not evaluated)** | 197 / 122 / 122 / 122 |
| PreToolUse | `guard-completeness-commits.sh` | `Bash` | passes, silent | passes, silent | passes, silent | passes, silent | **FAILS OPEN (predicate not evaluated)** | 227 / 54 / 130 / 54 |
| PreToolUse | `guard-row-currency-commits.sh` | `Bash` | passes, speaks | passes, silent | passes, silent | passes, silent | **FAILS OPEN (check lost)** | 1978 / 129 / 129 / 129 |
| PreToolUse | `guard-vendoring-commits.sh` | `Bash` | passes, speaks | passes, silent | passes, silent | passes, silent | **FAILS OPEN (check lost)** | 3229 / 162 / 164 / 164 |
| PreToolUse | `guard-workflow-ban.sh` | `Workflow` | **refuses** | **refuses** | **refuses** | **refuses** | **FAILS CLOSED** | 148 / 149 / 148 / 149 |
| Stop | `guard-unresolved-claims.sh` | `(all)` | passes, speaks | passes, silent | passes, silent | passes, silent | **FAILS OPEN (check lost)** | 183 / 170 / 189 / 182 |
| Stop | `turn-manifest.sh` | `(all)` | passes, speaks | passes, silent | passes, silent | passes, silent | **FAILS OPEN (check lost)** | 185 / 171 / 190 / 183 |
| Stop | `notice-hook-staleness.sh` | `(all)` | passes, speaks | passes, silent | passes, silent | passes, silent | **FAILS OPEN (check lost)** | 137 / 157 / 147 / 147 |
| Stop | `notice-inflight-acks.sh` | `(all)` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 228 / 217 / 236 / 229 |
| Stop | `notice-mechanical-findings.sh` | `(all)` | passes, speaks | passes, speaks | passes, speaks | passes, speaks | **payload-independent** | 2127 / 2116 / 2122 / 2128 |
| Stop | `notice-unstarted-rows.sh` | `(all)` | passes, speaks | passes, speaks | passes, speaks | passes, speaks | **payload-independent** | 2746 / 2735 / 2741 / 2747 |
| Stop | `notice-ceo-unasked.sh` | `(all)` | passes, speaks | passes, speaks | passes, speaks | passes, speaks | **payload-independent** | 304 / 293 / 299 / 305 |
| Stop | `notice-unasked-deferral.sh` | `(all)` | passes, speaks | passes, silent | passes, silent | passes, silent | **FAILS OPEN (check lost)** | 205 / 170 / 202 / 182 |
| Stop | `notice-ceo-ruled-prose.sh` | `(all)` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 249 / 238 / 257 / 250 |
| Stop | `notice-waiver-repetition.sh` | `(all)` | passes, speaks | passes, speaks | passes, speaks | passes, speaks | **payload-independent** | 169 / 158 / 164 / 170 |
| Stop | `notice-escalations.sh` | `(all)` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 166 / 155 / 174 / 167 |
| Stop | `guard-agent-state-claims.sh` | `(all)` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 201 / 184 / 207 / 196 |
| Stop | `guard-idle-land.sh` | `(all)` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 194 / 181 / 200 / 193 |
| Stop | `guard-stated-actions.sh` | `(all)` | **refuses** | passes, silent | passes, silent | passes, silent | **FAILS OPEN (proven)** | 194 / 181 / 200 / 193 |
| Stop | `notice-ceo-inputs-unheld.sh` | `(all)` | passes, silent | passes, silent | passes, silent | passes, silent | **INDETERMINATE** | 173 / 162 / 181 / 174 |

FAILS OPEN (proven)                      11
INDETERMINATE                            8
FAILS OPEN (predicate not evaluated)     7
FAILS OPEN (check lost)                  6
payload-independent                      5
FAILS CLOSED                             3

PreToolUse
   FAILS OPEN (proven)                    10
   FAILS OPEN (predicate not evaluated)   7
   FAILS CLOSED                           3
   INDETERMINATE                          2
   FAILS OPEN (check lost)                2
   payload-independent                    1
Stop
   INDETERMINATE                          6
   FAILS OPEN (check lost)                4
   payload-independent                    4
   FAILS OPEN (proven)                    1
