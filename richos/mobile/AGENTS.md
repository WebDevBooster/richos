# Mobile development

Every mobile feature, fix and refactor must preserve this development loop:

- Put application actions and semantic state in `core/`, without DOM or native UI dependencies. UI code invokes the same actions as the CLI.
- Reuse the existing PWA modules where applicable. Do not make a second queue, retry policy or test-only implementation of application behavior.
- Inject storage, transport, clock and platform operations. Extend deterministic scenarios when behavior changes. Add recording and update-policy scenarios when those features are implemented, using the real core with replaceable platform results.
- Run the focused headless checks first. Use the same CLI to enter simulator states directly when UI or native behavior matters. Verify visible controls through UI automation; direct core calls do not prove taps work.
- Keep fixtures and external development commands out of Release builds. Run `check-release` when changing the native bridge or packaging.
- Record actual feedback times privately in `richos-hq`. Keep build output and generated projects outside source on the external SSD. Follow the user's simulator-storage choice rather than silently changing system storage.
- Preserve the existing PWA. The current Swift/WKWebView shell is the minimal development host; it does not settle the final mobile framework or prove real-device microphone, APNs or managed networking behavior.
- Keep the Android PWA in the same development workflow. Use the CLI's `pwa` target for its actual UI and browser adapters. Shared behavior belongs in reusable headless modules; platform differences need explicit checks, not a second implementation of shared rules.

See `DEVELOPMENT.md` for commands and the verification boundaries.
