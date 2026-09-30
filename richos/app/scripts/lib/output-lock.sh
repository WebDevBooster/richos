# shellcheck shell=bash
# output-lock.sh — one packaging run at a time per OUTPUT DIRECTORY, from any checkout.
#
#   . "$here/lib/output-lock.sh"
#   hold_output_lock <dir> <fd> <what> || exit 1
#
# WHY (hunt part 2, section 21). `shared-build-cache.sh` links every developer checkout's
# `app/target` and `src-tauri/target` to one cache directory, and CARGO_TARGET_DIR can point
# several checkouts at one directory too. Cargo's own lock makes the COMPILES take turns, but
# it is released when cargo returns, and the packaging steps after it are shell: the Tauri
# bundle is signed, stamped and archived, and the engine tarball is written, digested and
# pinned, all by name. Two checkouts packaging at once therefore wrote one directory, and one
# of them could sign, digest or ship the other's half-written bytes. This lock covers those
# steps, and a second run waits for the first the way cargo waits for its build directory.
#
# THE LOCK IS THE DIRECTORY ITSELF: flock(2) on a descriptor open on <dir>. It is keyed by the
# directory's inode, so every path that reaches it (this checkout's `app/target`, another
# checkout's symlink into the shared cache, a CARGO_TARGET_DIR) names the same lock, with no
# name to derive and no lock file left in a directory whose files are release assets.
#
# HELD BY THE CALLING SHELL'S DESCRIPTOR <fd>. The python below only takes the lock on that
# inherited descriptor; a flock belongs to the open file description, which outlives the
# python process. It is released when the caller and every child that inherited <fd> have
# exited, so a packaging child left running after its parent died still holds it.
#
# RE-ENTRANT FOR CHILDREN. The physical path is added to RICHOS_OUTPUT_LOCKS, and a child that
# asks for a directory already listed there is told its caller holds it. That is how
# make-release.sh can hold the bundle directory across package-app.sh and its own use of the
# bundle afterwards, without deadlocking on itself.
#
# RICHOS_OUTPUT_LOCK_WAIT=<seconds> bounds the wait; past it, this refuses rather than waits.
# Unset, it waits as long as the other run takes, saying so once, as cargo does.

hold_output_lock() {  # hold_output_lock <dir> <fd> <what>
  local dir="$1" fd="$2" what="$3" physical
  case "$fd" in [3-9]) ;; *) echo "hold_output_lock: descriptor must be 3-9, got '$fd'" >&2; return 1 ;; esac
  mkdir -p "$dir" || { echo "cannot create $dir to lock it" >&2; return 1; }
  physical="$(cd "$dir" && pwd -P)" || return 1
  case ":${RICHOS_OUTPUT_LOCKS:-}:" in *":$physical:"*) return 0 ;; esac
  eval "exec $fd<\"\$physical\"" || { echo "cannot open $physical to lock it" >&2; return 1; }
  python3 - "$fd" "$physical" "$what" "${RICHOS_OUTPUT_LOCK_WAIT:-}" <<'PY' || { eval "exec $fd<&-"; return 1; }
import fcntl, sys, time
fd, path, what, limit = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
limit = float(limit) if limit else None
started = time.monotonic()
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sys.exit(0)
except BlockingIOError:
    pass
print(f"{what}: another packaging run is writing {path}; waiting for it to finish"
      + (f" (at most {limit:.0f}s)" if limit is not None else ""), file=sys.stderr, flush=True)
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(f"{what}: {path} is free after {time.monotonic() - started:.0f}s",
              file=sys.stderr, flush=True)
        sys.exit(0)
    except BlockingIOError:
        if limit is not None and time.monotonic() - started >= limit:
            print(f"REFUSING — {what}: {path} is still being written by another packaging run "
                  f"after {limit:.0f}s (RICHOS_OUTPUT_LOCK_WAIT); nothing was written",
                  file=sys.stderr, flush=True)
            sys.exit(1)
        time.sleep(0.5)
PY
  export RICHOS_OUTPUT_LOCKS="${RICHOS_OUTPUT_LOCKS:+$RICHOS_OUTPUT_LOCKS:}$physical"
}
