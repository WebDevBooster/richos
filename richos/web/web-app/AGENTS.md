# PWA development

The Android PWA remains a supported phone client alongside the iOS app. Use the common [mobile development loop](../../mobile/DEVELOPMENT.md) for PWA work:

- Keep application logic in headless modules with injectable dependencies. Extend the real shared modules and focused Node checks before connecting UI controls. Do not duplicate queue or retry rules for another platform.
- Use `node richos/mobile/cli/mobile.mjs pwa prepare` and the same CLI's PWA state, action, fixture, scenario and refresh commands from the repository root. This target serves the actual PWA and drives its visible controls.
- Run `pwa verify` for queue, persistence or reconnect changes. Use relevant existing browser checks and physical Android checks for microphone, permissions, notifications and lifecycle changes. Desktop Chromium emulation does not prove physical Android behavior.
- Keep fixtures and command access in development tooling. Do not add a remote development API to the shipped PWA.
- End browser sessions with `pwa stop`. Keep generated artifacts on the external SSD and private timing evidence in `richos-hq`.
