# A double-clicked RichOS, before and after — measured 2026-09-01

**Both runs are real LaunchServices launches of an installed `.app`, not a terminal.** `open`
hands the process to launchd exactly as a Finder double-click does: working directory `/`,
launchd's environment, none of the calling shell's. A unit test could not have produced either
line below, which is why the bug survived: nothing had ever launched the app that way.

Machine: macOS 15.6 (24G84), Apple M4. Bundles built with `app/scripts/package-app.sh`
(ad-hoc, exit 0), then copied to `~/Applications/` — **outside the repository tree**, so the
resolution cannot fall back on being run from a checkout. Same machine, same minute, one
variable: the two commits.

## The pair

`raw/dclick-installed-before.log` — `faa9b9d`, cdhash `25a06fe8fbd760a38510adc5235fdcaaa6434ca7`:

```
[richos] NO COMPUTE LEASE — RichOS cannot talk to Rich.
[richos]   binary: /Users/alex/.local/bin/claude
[richos]   cause : the claude binary was not found at /Users/alex/.local/bin/claude — RichOS drives Claude Code directly and cannot run without it
```

`raw/dclick-installed-fixed.log` — `970ac5e`, cdhash `a2feb8c7b416acb853a166a7e7b9e912241f757a`:

```
[richos] engine directory: /Users/alex/.claude/richos-engine (via engine install pointer)
[richos] compute lease attached over /Users/alex/.local/bin/claude
```

**`/Users/alex/.local/bin/claude` is present and executable in BOTH runs** — a symlink to
`~/.local/share/claude/versions/2.1.252`, unchanged between them. The first message was false
about the binary and silent about the directory.

## The other two logs

- `raw/dclick-fixed.log` — the same fixed build launched from **inside** the worktree tree,
  where candidate 4 answers first: `engine directory: …/echo-opus-d1/engine (via repo layout
  above the executable)`. The dogfood layout keeps working.
- `raw/dclick-installed-fixed-noengine.log` — the fixed build with
  `RICHOS_ENGINE_DIR=/Users/alex/no-such-engine-directory`, i.e. the case where the engine
  genuinely is not there. It now says so, and says which fault it is NOT:

  ```
  [richos]   engine: /Users/alex/no-such-engine-directory
  [richos]   cause : the engine directory /Users/alex/no-such-engine-directory does not exist — RichOS runs Claude with that directory as its working directory and cannot start without it (this is NOT a missing claude binary)
  ```

## Still broken after this, and it is in every log above

Every one of these launches — including the two that attach the lease — carries:

```
[richos] entity not resolved from /: unknown root /: no registered entity owns this path — refusing to guess
```

With no entity, `main.rs:242` refuses **every send**. A double-clicked RichOS therefore still
cannot be talked to, for a second reason that is not the engine directory and is not fixed
here. `BLOCKED.md` at the root of branch `echo-opus-d1` states it, with the question that
closes it.

## Reproducing

```
app/scripts/package-app.sh
cp -R app/src-tauri/target/release/bundle/macos/RichOS.app ~/Applications/RichOS-echo-d1.app
docs/verification/engine-resolution-2026-09-01/scripts/doubleclick.sh ~/Applications/RichOS-echo-d1.app installed-fixed
docs/verification/engine-resolution-2026-09-01/scripts/doubleclick-env.sh ~/Applications/RichOS-echo-d1.app installed-fixed-noengine RICHOS_ENGINE_DIR=/Users/alex/no-such-engine-directory
```

Both scripts write their capture to the scratch path in their `OUT=` line and print it; the
working directory of the running process is read back with `lsof -d cwd`, which reports `/`.
