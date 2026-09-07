# CEO experience improvement suggestions

These are observed opportunities outside the onboarding and waiting repairs. They are proposals, not completed features.

| Priority | Improvement | CEO benefit and observed reason |
| --- | --- | --- |
| High | Reduce the extra model round trip used for context preparation. | Real interview responses took seconds to tens of seconds. Investigate combining context installation with the visible request while preserving company isolation, memory retrieval and cancellation. Benchmark before changing the lifecycle again. |
| High | Independent conversation sessions or a bounded session pool. | A separate conversation could progress while another waits on the model. Async IPC fixes the main-loop stall but the current spine and conversation session remain shared. |
| High | Opt-in latency measurements and regression budgets. | Detect slow launch, context preparation, model responses and rendering before a customer reports them. Record phase durations without prompts or company content. |
| Medium | A shorter introduction with optional deeper onboarding. | The current twenty-minute invitation is a substantial commitment before a CEO sees value. |
| Medium | Review old company notes. | Notes have a date but no freshness workflow. A brief review would keep decisions grounded as the business changes. |
| Medium | Recoverable company-note history. | A CEO could inspect or undo a mistaken summary. Atomic writes prevent torn files but do not provide revision history. |
| Medium | One clear company-data location. | Company notes and the separate memory corpus have different locations. A unified setting and explicit migration would reduce confusion. |
| Medium | Distinguish desired roles from staffed roles. | The interview records staffing wishes honestly. A visible status would clarify which roles actually exist as working agents. |
| Medium | Shorter interview acknowledgements. | The live model repeated the same staffing limitations across multiple replies. State the boundary clearly and keep later replies focused on the next useful question. |
| Medium | Reduce empty assignment-panel copy during conversation. | The waiting screenshot shows “No assignment yet” and a full explanation while Rich is already answering. A compact empty state would leave more room for the conversation and its progress. |
| Low | Scope missing-plugin diagnostics to sessions that requested plugins. | The intentionally tool-free registrar prints a missing-skills warning. The primary chat tools work, but this false warning makes support logs harder to interpret. |
