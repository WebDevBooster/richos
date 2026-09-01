# BLOCKED (partial) — the double-click has a SECOND fatal stop, and it is not the engine directory

Raised by `echo-opus-d1`, 2026-09-01, against `richos` main `faa9b9d`.

**I am not blocked on my own task and I am proceeding with it.** This file exists because the
brief's premise — *"when he double-clicks it, it will tell him the Claude binary is missing …
Fixing that is the whole job"* — is **not true**, and the CEO is being handed this app tonight.

## What I am flagging

Fixing `engine_dir()` makes a double-clicked RichOS **attach the compute lease**. It does NOT
make it **talk to Rich**. A second cwd-derived refusal sits immediately behind it:

- `app/src-tauri/src/main.rs:374` `boot_entity()` resolves the ECS entity from
  `std::env::current_dir()` against `EntityRegistry::dogfood()`
  (`app/crates/richos-core/src/entity.rs:206-214` — four hard-wired roots under
  `/Users/alex/ab/`).
- A double-clicked `.app` has `cwd = /`, which owns no entity, so `boot_entity()` returns
  `None` **by deliberate fail-closed design** (§3.3 — "refusing to guess").
- With no entity, `main.rs:242` `send_message` refuses **every send** with
  `ENTITY_UNRESOLVED_MESSAGE`. Same for `main.rs:2129/2144/2162`.

So after my fix the boot log reads "compute lease attached", the window opens, and the first
thing the CEO types comes back as *"I can't tell which company this work belongs to…"*.

**Already measured, not predicted** — `echo-opus-p1`'s own raw log, committed at `faa9b9d`:
`docs/verification/payload-inventory-2026-09-01/raw/run-cwd-root.log:2`

```
[richos] entity not resolved from /: unknown root /: no registered entity owns this path — refusing to guess
```

p1's `cwd-isolate.sh:12` exports `RICHOS_ENTITY=richos` before its two runs, which is why the
isolation pair does not show this line — the variable was pinned to isolate the engine-dir
question. It is not fixed; it was held constant.

## What I already tried

- Re-read the resolution path end to end (`boot_entity` → `resolve_root` → `send_message`) to
  confirm the refusal is total rather than cosmetic. It is total: no send completes.
- Looked for a non-cwd route to an entity. There is exactly one: the `RICHOS_ENTITY`
  environment variable, which a Finder double-click cannot set.
- Considered resolving the entity from the engine directory I am now resolving
  (`/Users/alex/ab/richos/engine` → entity `richos`). **I did not build it.** Which company a
  copy of Rich works for is the decision the code deliberately refuses to make on its own, and
  it is not mine to make in a bug fix.

## The smallest question that would unblock it

**When RichOS is launched with no working directory and no `RICHOS_ENTITY` — the only way the
CEO will ever launch it — which entity do his conversations file under?** Any one of these
closes it; all are small:

1. A default entity for a GUI launch (`richos`), stated in the boot log.
2. Read the entity from the durable config store (`config.json`, already open at boot) and ask
   once in the UI if unset.
3. Ship the `.app` with the entity baked into `Info.plist`/a resource file at package time.

## What I am proceeding on meanwhile

My assigned scope, unchanged and in full: (1) a launch failure names what is actually missing
instead of reporting a missing working directory as a missing binary; (2) engine-directory
resolution that works for a double-clicked bundle, explicit and testable. Both land committed
on `echo-opus-d1` with red-first test evidence and a real Finder-launch boot line, whatever is
decided about the entity.
