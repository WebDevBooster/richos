# Copywriting re-vendoring regression fixture

`natural-transitions.md` contains the complete upstream file before the four
spelling changes described in `engine/skills/copywriting/LICENSE`. It is test
input, not an installed skill.

- Upstream: https://github.com/coreyhaines31/marketingskills
- Revision: `68f5eaf64e858438db47e436d7a3bef0e9d69721`
- Upstream path: `skills/copywriting/references/natural-transitions.md`
- Local provenance: extracted without modification from
  `06f4a8221a61^:engine/skills/copywriting/references/natural-transitions.md`
- SHA-256: `4ff23f8943af2f65b072f26f1c53ce55f19cc26d7be211c11cae8e34b43e859f`
- License: MIT, copyright 2025 Corey Haines. See the adjacent `LICENSE`.

The test reads these pinned bytes without network access or repository history.
It sends the same complete file to third-party and first-party destinations:
re-vendoring must pass and applying the same spelling to first-party material
must fail. Removing the fixture is a failure, never a skipped check.
