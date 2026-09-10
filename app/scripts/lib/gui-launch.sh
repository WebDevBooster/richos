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
#
# ---------------------------------------------------------------------------------------
# AND WHY IT IS A REAL BUNDLE AND NOT A DIRECTORY SHAPED LIKE ONE
# ---------------------------------------------------------------------------------------
#
# For nine days it was the latter, and the boot died on its first line. `gui_bundle_plist`
# below carries the full diagnosis; the short version is that once `main()` began calling
# `update_startup::prepare`, a `.app` with no `Contents/Info.plist` stopped being a launch
# this product would complete. A harness that boots something the product refuses is not
# testing a launch, and — worse — its NEGATIVE cases keep passing, because a boot that never
# happens looks exactly like a boot that failed for the reason each of them broke.

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

  # -- the central folder, and the ONE thing here that is deliberately not provisioned ----
  #
  # `~/myrichos/companies/<id>/company.md` is what the CEO said about his company, and
  # `company.rs` reads it at prime time. It is written HERE, in the harness, rather than by
  # the example above, and that is the point rather than an oversight: RichOS does not create
  # this folder and must not. A reader that helpfully created its own source could never
  # report the source missing, which is how this machine ended up with four `corpus.*`
  # symlinks pointing at a directory that is not there
  # (`richos-central-folder-2026-09-06.md` §1.3, `company.rs`).
  #
  # So a COMPLETE machine has one because somebody put it there, and B3-B8 — which build
  # their machines the same way and then break one thing — inherit it too. The company id is
  # `northwind`, the same one `gui_boot_machine.rs` registers; a file under any other id
  # would leave the boot printing `nothing on file` and would look like a product failure.
  mkdir -p "$home/myrichos/companies/northwind" || return 1
  cat > "$home/myrichos/companies/northwind/company.md" <<'COMPANY'
# Northwind

Recorded from a conversation with the CEO, 2026-09-06.

## What the business is

Northwind sells chandlery to working harbors. Its customers are harbor masters, not sailors.

## Who he wants around him

Not discussed yet.
COMPANY

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

  # -- the binary, OUTSIDE the repository, IN A BUNDLE THE PRODUCT WILL ACCEPT -----------
  local ident identifier version
  ident="$(gui_identity "$GUI_BINARY")" || return 1
  identifier="${ident%% *}"; version="${ident##* }"
  gui_bundle "$home/Applications/RichOS.app" "$GUI_BINARY" "$identifier" "$version" || return 1
  echo "bundle identity : $identifier $version (asked of the binary, not typed here)"
  echo "binary          : $home/Applications/RichOS.app/Contents/MacOS/richos-tauri"
  return 0
}

# ---------------------------------------------------------------------------------------
# gui_identity <executable>
#
# ASK THE BINARY WHO IT IS. Prints `<identifier> <version>`.
#
# `update_startup::identity_probe` answers `--richos-internal-update-identity` with
# `{"identifier": …, "version": …, "protocol": 1}` and returns, BEFORE home resolution,
# before any lease and before Tauri exists (update_startup.rs:14-27). It is the installer's
# own way of asking a candidate executable what it is, and it is the right source here for
# one reason: the Info.plist below has to carry the version the binary will COMPARE it
# against, and every other source of that number is a copy that can disagree.
#
# The number matters more than it looks. `update_startup::prepare` reads the bundle version
# and, when it differs from the compiled version, treats the running application as CHANGED
# (`loaded_bundle_changed`, update_startup.rs:74-78); with no publication receipt on the
# machine that path returns `Err("Changed application has no publication receipt.")` and the
# boot is over before it prints a line. A plist carrying a hand-typed version would fail the
# same way the missing plist did, for a different reason and with an even stranger message.
#
# No GUI, no window, no runtime: the probe is a `println!` and a return.
# ---------------------------------------------------------------------------------------
gui_identity() {
  local exe="$1" out identifier version
  if ! out="$("$exe" --richos-internal-update-identity 2>/dev/null)"; then
    echo "gui_identity: $exe did not answer --richos-internal-update-identity" >&2
    return 1
  fi
  identifier="$(printf '%s' "$out" | sed -n 's/.*"identifier"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  version="$(printf '%s' "$out" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ -z "$identifier" ] || [ -z "$version" ]; then
    echo "gui_identity: could not read an identifier and a version out of the probe's answer:" >&2
    printf '  %s\n' "$out" >&2
    return 1
  fi
  printf '%s %s\n' "$identifier" "$version"
  return 0
}

# ---------------------------------------------------------------------------------------
# gui_bundle_plist <identifier> <version> <executable-name>
#
# The `Info.plist` of the bundle this harness boots, on stdout.
#
# ---------------------------------------------------------------------------------------
# WHY THIS EXISTS AT ALL, AND WHAT IT COST NOT TO HAVE IT
# ---------------------------------------------------------------------------------------
#
# Until 2026-09-10 this harness copied the executable into `RichOS.app/Contents/MacOS/` and
# wrote NO `Info.plist` — a directory shaped like a bundle that was not one. That was fine
# until `01e9b8d8` put `update_startup::prepare` at the top of `main()`: it takes the bundle
# root around the executable (`activation::bundle_root`, a pure path-shape test that this
# layout satisfies) and then reads `Contents/Info.plist` (`richos_user_update::bundle_plist`,
# lib.rs:570-575). There was no such file, so `prepare` returned `Err`, `main` printed
#
#     [richos] application startup: No such file or directory (os error 2)
#
# and returned. Every boot in this suite died at line one. B1 and B2 went red — and B3-B8,
# the six negative halves, went GREEN over the same dead boot, because a machine that never
# boots is indistinguishable from a machine with its engine pointer removed. Measured on
# 2026-09-10 against `7272ecf8`: `3 FAILED, 18 passed`, six of those passes false.
#
# THE KEYS ARE NOT A LIST SOMEBODY MAINTAINS. `C2` below extracts the `Info.plist` keys the
# product's own `bundle_version` reads out of `richos-user-update/src/lib.rs` and asserts
# this function emits every one of them, so a key the product STARTS requiring makes that
# case red rather than making this file quietly insufficient. Drift lengthens the list.
#
# The file-shape rules `bundle_plist` enforces beyond parsing (a regular file, one link,
# under 1 MiB, no group- or other-write bit, no write ACL — lib.rs:576-586) are satisfied by
# `gui_bundle` writing it and chmod 644, and asserted by `C4`.
# ---------------------------------------------------------------------------------------
gui_bundle_plist() {
  local identifier="$1" version="$2" exe_name="$3"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$identifier</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>CFBundleExecutable</key>
	<string>$exe_name</string>
	<key>CFBundleName</key>
	<string>RichOS</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
</dict>
</plist>
PLIST
}

# ---------------------------------------------------------------------------------------
# gui_bundle <bundle-root> <executable> <identifier> <version>
#
# Lay out a `.app` the product accepts: `Contents/MacOS/<name>` and `Contents/Info.plist`.
#
# IT TAKES THE EXECUTABLE AS AN ARGUMENT, and that is not decoration. `C1`-`C4` call this
# with a stand-in executable in a scratch directory, so the bundle this harness gives the
# product is held to account on a host that can build no machine and boot nothing — which is
# every public runner, and is the only place the defect above would ever have been seen.
# A version of this that reached for `$GUI_BINARY` itself would be untestable exactly where
# the testing was needed.
#
# Directory modes are 755 rather than left to the umask: `owned_dir` (lib.rs:120-126)
# refuses any application directory carrying a group- or other-write bit.
# ---------------------------------------------------------------------------------------
gui_bundle() {
  local root="$1" exe="$2" identifier="$3" version="$4"
  local name; name="$(basename "$exe")"
  mkdir -p "$root/Contents/MacOS" || return 1
  chmod 755 "$root" "$root/Contents" "$root/Contents/MacOS" || return 1
  cp "$exe" "$root/Contents/MacOS/$name" || return 1
  chmod 755 "$root/Contents/MacOS/$name" || return 1
  gui_bundle_plist "$identifier" "$version" "$name" > "$root/Contents/Info.plist" || return 1
  chmod 644 "$root/Contents/Info.plist" || return 1
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
