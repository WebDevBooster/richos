# Corrected UUID fixture: ready for real reboot

The package from source `1e3e499` was installed successfully on 2026-09-07.
All 26 installed managed lifecycle checks passed, including normal timer-driven
reclamation and clean broker shutdown. Its disposable managed fixtures were
removed. The corrected 22-module installed release was verified against its
manifest and remains inactive for production: no live LaunchDaemon plist,
public `client.json` or production broker socket exists.

A fresh tiny generated repository and linked worktree passed all preboot checks:
owner access was revoked, the already-open descriptor's final bytes survived
and the same-boot job remained held with no capture or deletion. Its persisted
filesystem identities contain native volume UUIDs. The first failed fixture is
retained unchanged and must not be reused for this test.

## Next step

A real Mac reboot is now required to test the durable identities and prove that
old writable descriptors cannot survive. Restarting Claude alone is insufficient.
Save current work before restarting. No real repository is gated by this test.
After reboot, run this exact installed command through the native administrator
launcher. Do not run it before reboot or prepare another replacement fixture.

```sh
/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B '/Library/Application Support/RichOS/workspace-broker/releases/bd03b3b3bbfffdf74cdf3d61730fddc1297ece1a5fbd54d718444120289ced7a/legacy-workspace-acceptance.py' resume --acceptance-id legacy-acceptance-dd90b50171b64dc1961f9112b12147c0 --approved-plan-sha256 e2c31acf89116bc841e4578dfdbe9280f982536dd411a99b2aa0ca9c9aaed290
```

The driver checks the exact release, immutable plan and a different actual kernel
boot UUID. It runs the previously armed job through the isolated installed broker
and verifies recovery, worktree/branch retirement, restoration, immediate Git-GC
survival and idempotent completion. Production activation is still separate.

- Acceptance ID: `legacy-acceptance-dd90b50171b64dc1961f9112b12147c0`
- Gate ID: `428471af-1917-490f-a8cc-f600056d0515`
- Plan SHA256: `e2c31acf89116bc841e4578dfdbe9280f982536dd411a99b2aa0ca9c9aaed290`
- Selection SHA256: `fea0ac0ae353ff7425668d350a1e41bb37b178e8825a47baead3a47bb9e496dc`
- Preboot kernel UUID: `c6f84dc3-a79a-4506-8759-d2de887ea19a`
- Private receipt: `/private/var/db/richos-workspaces/legacy-acceptance-dd90b50171b64dc1961f9112b12147c0/receipt.json`

Do not signal the old holder PID after reboot because it may have been reused.
If resume fails, preserve the fixture and original plan/selection unchanged.
Read the protected receipt and broker log before taking recovery action.

Evidence: [managed lifecycle](managed-workspace-uuid-installed-lifecycle-2026-09-07.json),
[preparation](legacy-workspace-uuid-installed-preparation-2026-09-07.json) and
[staging](legacy-workspace-uuid-installed-preboot-2026-09-07.json).
