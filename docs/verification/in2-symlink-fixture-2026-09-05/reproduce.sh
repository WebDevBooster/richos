#!/usr/bin/env bash
# IN2 reproduction, take 2.
#
# Take 1 was INVALID and said so in its own output: `mktemp -d -t` on macOS ignores TMPDIR
# and always lands in /var/folders/.../T, which is a symlink to /private/var/..., so the arm
# that was supposed to remove the symlink never did. The sandbox path in the failure text was
# /private/var/... — the physicalized form — which is what gave it away.
#
# So the sandbox path is now controlled in the COPIED fixture instead of through the
# environment, by replacing its `mktemp -d -t` with a `mktemp -d <dir>/template`.
#
#   REAL   sandbox has no symlink in any component  = the Linux condition
#   LINK   sandbox reached through a symlink        = the macOS condition
#
# Four arms: each path shape, mutated and unmutated. The unmutated arms are the controls that
# prove a red arm is red because of the MUTATION and not because of the path shape.
set -uo pipefail
ENGINE_ROOT=/Users/alex/ab/richos-wt/zach-opus-rd1/engine
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad/rd1

REALBASE="$SP/tmp-real"
LINKTARGET="$SP/tmp-linktarget"
LINKBASE="$SP/tmp-link"
rm -rf "$REALBASE" "$LINKTARGET" "$LINKBASE"
mkdir -p "$REALBASE" "$LINKTARGET"
ln -s "$LINKTARGET" "$LINKBASE"

build() {   # build <dir> <sandbox-base>
    local dir="$1" base="$2"
    rm -rf "$dir"; mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/guard-inflight-notify.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-inflight-sends.sh" \
       "$ENGINE_ROOT/scripts/hooks/notice-inflight-acks.sh" \
       "$ENGINE_ROOT/scripts/hooks/inflight-notify.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/inflight.sh" "$ENGINE_ROOT/scripts/lib/inflight.py" \
       "$ENGINE_ROOT/scripts/lib/teammate-identity.py" \
       "$ENGINE_ROOT/scripts/lib/agent-liveness.py" \
       "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" \
       "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" \
       "$ENGINE_ROOT/scripts/lib/git-jurisdiction.sh" \
       "$ENGINE_ROOT/scripts/lib/stop-hook-notice.sh" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/scripts/inflight-notify.sh" "$ENGINE_ROOT/scripts/inflight-ack.sh" "$dir/scripts/"
    chmod +x "$dir/scripts/hooks/"*.sh "$dir/scripts/"*.sh
    # Point the fixture's sandbox at the base we want. REFUSE if the anchor is not there.
    python3 - "$dir/scripts/hooks/inflight-notify.test.sh" "$base" <<'PY'
import sys
p, base = sys.argv[1], sys.argv[2]
old = 'SANDBOX="$(mktemp -d -t inflight-notify.XXXXXX)"'
new = 'SANDBOX="$(mktemp -d "%s/inflight-notify.XXXXXX")"' % base
s = open(p, encoding='utf-8').read()
if old not in s:
    sys.stderr.write('SANDBOX ANCHOR ABSENT — this experiment would prove nothing\n'); sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
}

mutate() {
    python3 - "$1/scripts/lib/inflight.py" <<'PY'
import sys
p = sys.argv[1]
old = '    return os.path.realpath(os.path.abspath(path)).rstrip("/")'
new = '    return os.path.abspath(path).rstrip("/")'
s = open(p, encoding='utf-8').read()
if old not in s:
    sys.stderr.write('MUTATION TARGET ABSENT — this experiment would prove nothing\n'); sys.exit(3)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
}

arm() {     # arm <label> <base> <mutate:yes|no>
    local label="$1" base="$2" domut="$3"
    local dir="$SP/in2b-$label"
    build "$dir" "$base" || { echo "  BUILD FAILED"; return 1; }
    if [ "$domut" = yes ]; then mutate "$dir" || { echo "  MUTATION FAILED"; return 1; }; fi
    printf '\n--- %s ---\n  sandbox base : %s\n  physical     : %s\n  symlinked    : %s\n  mutated      : %s\n' \
        "$label" "$base" "$(cd "$base" && pwd -P)" \
        "$([ "$base" = "$(cd "$base" && pwd -P)" ] && echo NO || echo YES)" "$domut"
    bash "$dir/scripts/hooks/inflight-notify.test.sh" >"$dir/out.txt" 2>&1
    local rc=$?
    # Prove the sandbox really sat where we asked, from the run's own output.
    printf '  sandbox seen : %s\n' "$(grep -o '/[^ ]*inflight-notify\.[A-Za-z0-9]*' "$dir/out.txt" | head -1)"
    printf '  suite exit   : %s  ' "$rc"
    if [ "$rc" -eq 0 ]; then echo "=> GREEN"
    elif grep -q "FAIL  5j\." "$dir/out.txt"; then echo "=> RED at 5j"
    else echo "=> RED elsewhere: $(grep -c '  FAIL' "$dir/out.txt") case(s)"; fi
}

arm "REAL-unmutated" "$REALBASE" no
arm "REAL-mutated"   "$REALBASE" yes
arm "LINK-unmutated" "$LINKBASE" no
arm "LINK-mutated"   "$LINKBASE" yes
