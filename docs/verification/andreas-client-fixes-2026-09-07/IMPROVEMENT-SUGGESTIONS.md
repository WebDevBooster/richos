# CEO experience improvement suggestions

This list records useful ideas found while fixing Andreas's onboarding and waiting defects. They are outside this repair's scope and are not claims about completed features.

| Priority | Suggestion | User benefit | Evidence or trigger |
| --- | --- | --- | --- |
| High | Give each independent conversation its own compute lease or schedule requests across a pool. | A CEO could start a separate conversation while another is waiting on long model work. | The current shell shares one long-held spine and one conversation lease across threads. Moving IPC off the main thread restores responsiveness but does not create independent compute capacity. |
| High | Add an opt-in, privacy-preserving latency dashboard and regression budget. | Identify whether delays come from launch, context preparation, provider response or rendering before a client has to report them. | Existing evidence measured isolated model operations and UI states rather than end-to-end response distributions. Store durations and phase names without prompts or company content. |
| Medium | Offer a shorter initial business introduction followed by optional deeper onboarding. | A new CEO could get value without committing to twenty minutes before using the product. | The current invitation offers a single twenty-minute interview. |
| Medium | Review saved company notes with the CEO when they become old. | Keep decisions grounded in the current business as roles, customers and priorities change. | Notes have a date but no review reminder or freshness workflow. |
| Medium | Add a visible distinction between company setup and actual team staffing. | Make it easy to see which desired roles exist as working agents and which are only recorded wishes. | The interview correctly refuses to claim that recorded roles have been hired. Completing staffing is a separate product capability. |

New suggestions should describe the actual user benefit, the observed trigger and why they do not belong in this repair. Do not turn this list into an unprioritized feature backlog.
