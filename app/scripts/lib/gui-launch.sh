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
  mkdir -p "$home" || return 1
  ( cd "$app_dir" && cargo run -q -p richos-core --example gui_boot_machine -- "$home" ) || return 1

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
# ---------------------------------------------------------------------------------------
gui_boot() {
  local home="$1" out="$2" limit="${3:-60}"
  local bin="$home/Applications/RichOS.app/Contents/MacOS/richos-tauri"
  : > "$out"

  # cwd=/ and an empty environment, exactly as measured. `USER` is passed because launchd
  # passes it; nothing reads it, and leaving it out would make this a condition no launch
  # actually produces.
  ( cd / && env -i HOME="$home" USER="${USER:-unknown}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$bin" >> "$out" 2>&1 ) &
  local pid=$!

  local waited=0
  while [ "$waited" -lt "$((limit * 10))" ]; do
    if grep -q '^\[richos\] boot complete' "$out" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 0
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
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "[gui_boot] no 'boot complete' within ${limit}s" >> "$out"
  return 7
}
