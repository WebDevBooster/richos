#!/usr/bin/env bash
#
# gui-launch.sh — build a complete machine, and boot the shipped binary on it the way
# LaunchServices boots it.
#
# Sourced by `gui-boot.test.sh`. It is a library and not a suite: everything here is
# MACHINERY, and every VERDICT lives in the suite, where a reader looking for what is
# asserted finds it in one file.
#
# ---------------------------------------------------------------------------------------
# THE CONDITION, MEASURED RATHER THAN ASSUMED
# ---------------------------------------------------------------------------------------
#
# `ps eww` on a real Finder double-click of RichOS.app on this machine carries exactly:
#
#   HOME=/Users/alex  USER=alex  PATH=/usr/bin:/bin:/usr/sbin:/sbin
#
# and the working directory is `/`. That is recorded in
# `docs/verification/loro-write-path-2026-09-01/` and in `engine.rs`'s module doc, and it is
# the whole reason three separate components resolved their configuration out of variables
# that were not there. `env -i` reproduces it exactly: nothing is inherited, so a variable
# this harness does not name cannot rescue the boot the way a developer's shell does.
#
# `/usr/bin/open` is NOT used and must not be: it forwards the CALLER's environment, which is
# how every boot log in this repository before 2026-09-01 came to be a developer's launch
# wearing a double-click's clothes (commit 8b7ca41).
#
# ---------------------------------------------------------------------------------------
# WHY THE BINARY IS COPIED OUT OF THE REPOSITORY BEFORE IT IS RUN
# ---------------------------------------------------------------------------------------
#
# `engine.rs`'s candidate 4 is "the nearest ancestor of the EXECUTABLE holding an engine/".
# A binary sitting in `app/src-tauri/target/debug/` satisfies it, so a boot from there finds
# an engine no matter how badly the resolution is broken for a customer — the dogfood
# checkout answers on the executable's behalf. Every boot log in this repository so far was
# taken that way, and each one says `via repo layout above the executable`.
#
# So the binary is copied to `<machine>/Applications/RichOS.app/Contents/MacOS/richos-tauri`
# first. Candidates 4 and 5 then miss, and the engine has to be found the way it is found on
# a customer's Mac: through `<home>/.claude/richos-engine`, candidate 6.

set -uo pipefail

# ---------------------------------------------------------------------------------------
# gui_compiler_source
#
# Where 37 files of loro can be COPIED FROM, for the scratch corpus. Prints a path, or
# nothing and exit 1.
#
# THE FIXTURE MUST NOT BE BUILT BY THE COMPONENT IT TESTS, and this function is here
# because the first version of it was. It called `LoroInstall::locate` — the boot's own
# resolution — which is elegant right up until the moment somebody breaks that resolver,
# which is the moment this check exists for. Measured: with the pre-`c179cc1` read path put
# back, the fixture could not build a machine and the suite exited 2 saying "this machine has
# no loro compiler to copy". Red, so nothing failed open — and the wrong diagnosis, which
# sends its reader hunting a missing checkout instead of the defect that is right there.
#
# So this looks at facts that pass through no Rust code:
#
#   1. `$RICHOS_LORO_SOURCE` — the installer input `provision::resolve_compiler_source`
#      already honors. An operator who names one means it.
#   2. `~/Library/Application Support/RichOS/loro-tools` — where provisioning installs it.
#   3. the target of the corpus pointer, plus `/loro` — the in-repo dogfood shape, read with
#      `readlink`, which is a file-system fact and not a resolution.
#
# THREE CANDIDATES AND NO MORE, and this is not the inventory the suite's header refuses.
# That refusal is about lists that describe the PRODUCT's configuration, where drift makes
# the list quietly shorter and the result quietly greener. This list is a fixture INPUT: if
# it drifts and finds nothing, the machine is not built, the suite exits 2, and run-tests.sh
# reports a failed suite. Its failure mode is red.
gui_compiler_source() {
  local looks_like_loro=""
  local c
  for c in \
      "${RICHOS_LORO_SOURCE:-}" \
      "$HOME/Library/Application Support/RichOS/loro-tools" \
      "$(readlink "$HOME/Library/Application Support/RichOS/corpus" 2>/dev/null)/loro" \
      "$(readlink "$HOME/Library/Application Support/RichOS/loro-root" 2>/dev/null)/loro" ; do
    [ -n "$c" ] || continue
    [ "$c" = "/loro" ] && continue
    if [ -f "$c/bin/loro-context.mjs" ] && [ -f "$c/bin/loro-write.mjs" ]; then
      looks_like_loro="$c"; break
    fi
  done
  if [ -z "$looks_like_loro" ]; then
    echo "gui_compiler_source: no loro checkout on this machine to copy from. Looked at" >&2
    echo "  \$RICHOS_LORO_SOURCE, the loro-tools install, and the corpus pointer's own loro/." >&2
    return 1
  fi
  printf '%s\n' "$looks_like_loro"
  return 0
}

# ---------------------------------------------------------------------------------------
# gui_machine <scratch-root>
#
# Build the machine. Everything it creates is under <scratch-root>; nothing it does can
# reach the real `$HOME`. Prints what it made. Non-zero means the machine could not be
# built, which is never a verdict about the code under test.
# ---------------------------------------------------------------------------------------
gui_machine() {
  local home="$1"
  local app_dir="$GUI_APP_DIR"

  # -- the corpus, the loro tools, the pointer and the saved company ---------------------
  # Every one of them through the product's own `provision`, so this cannot describe a
  # machine RichOS does not create. See examples/gui_boot_machine.rs.
  local src
  src="$(gui_compiler_source)" || return 1
  mkdir -p "$home" || return 1
  ( cd "$app_dir" && cargo run -q -p richos-core --example gui_boot_machine -- "$home" "$src" ) || return 1

  # -- the engine, at the pointer an installed app reaches -------------------------------
  # `engine.rs` candidate 6: `$CLAUDE_CONFIG_DIR`(or `~/.claude`)`/richos-engine`, which is
  # the pointer `engine/scripts/hooks/install.sh` mints. A symlink, because that is what the
  # installer makes.
  mkdir -p "$home/.claude" || return 1
  ln -sfn "$GUI_ENGINE_DIR" "$home/.claude/richos-engine" || return 1

  # -- a `claude` binary, at the path `resolve_claude_bin` step 2 names -------------------
  # A STAND-IN, and it is honest about being one. It answers the single control request the
  # boot makes (`initialize`, native.rs::handshake) and then stays alive; it runs no model,
  # holds no credential and is never prompted, because the boot never prompts. What it
  # stands in for is the FACT that a claude binary is installed — which is a configuration,
  # and therefore something this check has to be able to have present in order for its
  # absence to mean anything.
  mkdir -p "$home/.local/bin" || return 1
  cat > "$home/.local/bin/claude" <<'STUB'
#!/usr/bin/env node
// A stand-in for the claude binary. It answers `initialize` and then idles. See
// app/scripts/lib/gui-launch.sh for why a stand-in is the right thing here.
process.stdin.setEncoding("utf8");
let buf = "";
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let msg;
    try { msg = JSON.parse(line); } catch (_) { continue; }
    if (msg.type === "control_request") {
      process.stdout.write(JSON.stringify({
        type: "control_response",
        response: { request_id: msg.request_id, subtype: "success" },
      }) + "\n");
    }
  }
});
process.stdin.on("end", () => process.exit(0));
setInterval(() => {}, 1 << 30);
STUB
  chmod +x "$home/.local/bin/claude" || return 1

  # `node` is on no GUI process's PATH, so the stand-in is given an absolute interpreter the
  # same way `resolve_node_bin` gives the compiler one. Without this the shebang fails under
  # launchd's PATH and the boot reports a lease failure that is the harness's fault.
  local node
  node="$(command -v node)"
  [ -n "$node" ] || { echo "gui_machine: no node on PATH — cannot build the stand-in" >&2; return 1; }
  sed -i '' "1s|.*|#!$node|" "$home/.local/bin/claude" || return 1

  # -- the binary, OUTSIDE the repository ------------------------------------------------
  mkdir -p "$home/Applications/RichOS.app/Contents/MacOS" || return 1
  cp "$GUI_BINARY" "$home/Applications/RichOS.app/Contents/MacOS/richos-tauri" || return 1
  echo "binary          : $home/Applications/RichOS.app/Contents/MacOS/richos-tauri"
  return 0
}

# ---------------------------------------------------------------------------------------
# gui_boot <scratch-root> <output-file> [seconds]
#
# Boot it, capture stderr, and stop the moment the process says it has finished resolving.
#
# TERMINATION IS A FACT, NOT A SLEEP. The app prints `[richos] boot complete` as the last
# line of `setup`; this waits for THAT and kills the process the moment it arrives. A
# harness that slept for a fixed number of seconds would be reading a different amount of
# boot log on a busy machine than on an idle one, which is the precise shape of a check that
# goes red for no reason and stops being believed.
#
# Exit 0: the marker arrived. Exit 7: the timeout expired first — which is a REAL failure
# ("this build did not finish booting"), reported as one and never as a pass.
#
# ---------------------------------------------------------------------------------------
# EVERY LAUNCH IS KILLED BY THE THING THAT MADE IT, ON EVERY PATH
# ---------------------------------------------------------------------------------------
#
# THIS WAS WRONG AND IT REACHED THE CEO'S DOCK. The first version of this function wrote
#
#     ( cd / && env -i ... "$bin" >> "$out" 2>&1 ) &
#     local pid=$!
#
# and `$!` there is the SUBSHELL, not the app. `cd / && env …` is a compound list, so bash
# forks a subshell which then forks `env`, which execs the binary — and the `kill` below
# reached the first of them. The app was orphaned to PID 1 and kept running with its window.
# Measured on 2026-09-01: 157 live `richos-tauri` processes, roughly six per round across
# about twenty-six rounds, every one from a `<tmp>/…/RichOS.app` whose directory had already
# been deleted. Deleting a temp directory does not kill what is running out of it —
# CLAUDE.md's zombie-residue rule, in the exact shape the rule describes.
#
# Three changes, and each is load-bearing:
#
#   1. `exec` — the subshell REPLACES itself with the binary, so `$!` is the app's own pid.
#      One process, and the pid this function holds is the pid it needs to signal.
#   2. TERM, then a bounded wait, then KILL, then VERIFY the pid is gone. A signal sent is
#      not a process ended.
#   3. every pid is appended to `$GUI_LAUNCHED_PIDS` before the wait begins, so the caller's
#      EXIT trap can reap it even if this function is interrupted before it gets to kill it.
#      The FAILING rounds are exactly the ones that leave processes behind.
# ---------------------------------------------------------------------------------------
gui_boot() {
  local home="$1" out="$2" limit="${3:-60}"
  local bin="$home/Applications/RichOS.app/Contents/MacOS/richos-tauri"
  : > "$out"

  # cwd=/ and an empty environment, exactly as measured. `USER` is passed because launchd
  # passes it; nothing reads it, and leaving it out would make this a condition no launch
  # actually produces. `exec` so that this subshell IS the app — see the header above.
  ( cd / && exec env -i HOME="$home" USER="${USER:-unknown}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$bin" >> "$out" 2>&1 ) &
  local pid=$!
  [ -n "${GUI_LAUNCHED_PIDS:-}" ] && printf '%s\n' "$pid" >> "$GUI_LAUNCHED_PIDS"

  local rc=7 waited=0
  while [ "$waited" -lt "$((limit * 10))" ]; do
    if grep -q '^\[richos\] boot complete' "$out" 2>/dev/null; then
      rc=0
      break
    fi
    # The process can also DIE before finishing — a panic in `setup`, a failed window
    # build. That is a result, not a reason to wait out the clock.
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      echo "[gui_boot] the process exited before printing 'boot complete'" >> "$out"
      return 7
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$rc" -eq 7 ] && echo "[gui_boot] no 'boot complete' within ${limit}s" >> "$out"
  gui_kill "$pid" || echo "[gui_boot] pid $pid SURVIVED both TERM and KILL" >> "$out"
  wait "$pid" 2>/dev/null
  return "$rc"
}

# ---------------------------------------------------------------------------------------
# gui_kill <pid>
#
# End it, and PROVE it ended. Exit 0 when the pid is gone, 1 when it survived both signals —
# which the caller reports rather than swallowing, because a kill that failed quietly is how
# 157 of these accumulated.
# ---------------------------------------------------------------------------------------
gui_kill() {
  local pid="$1" i=0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null
  i=0
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------------------
# gui_reap_all
#
# The backstop, run from the suite's EXIT trap so it runs on the failing paths too. Kills
# every pid this run recorded, then prints how many survived — a NUMBER, so "there is no
# residue" is measured rather than assumed.
#
# It only ever touches pids THIS RUN launched, read out of `$GUI_LAUNCHED_PIDS`. The CEO's
# own install at ~/Applications/RichOS.app is never started here and no signal from here can
# reach it.
# ---------------------------------------------------------------------------------------
gui_reap_all() {
  local survivors=0 pid
  if [ -n "${GUI_LAUNCHED_PIDS:-}" ] && [ -f "$GUI_LAUNCHED_PIDS" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      gui_kill "$pid" || survivors=$((survivors + 1))
    done < "$GUI_LAUNCHED_PIDS"
  fi
  printf '%s\n' "$survivors"
}
