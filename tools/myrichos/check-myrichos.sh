#!/usr/bin/env bash
#
# check-myrichos.sh — the check that makes §1.3's pointers CHECKED pointers.
#
# WHY THIS EXISTS, IN ONE MEASUREMENT. The design's §7 concedes the strongest objection against
# it: a central folder is a second place for things to go stale, and this machine already proves
# pointers rot. Run it yourself:
#
#     ls -l "$HOME/Library/Application Support/RichOS/"
#
# Four symlinks — `corpus.RAY-101-RUN-A`, `-RUN-B`, `-RUN-C`, `corpus.RAY-STRANGER-RUN-2026-09-04`
# — all point at `/Users/alex/RichOS/corpus`, and `ls -d /Users/alex/RichOS` exits 1. Nothing ever
# told anybody. §1.3's answer is that a pointer whose target is missing is an ERROR, not a
# fallback, and an error nothing computes is a wish. This script computes it.
#
# WHAT IT CHECKS
#   1. The folder exists, and its shape is the shape the design names.
#   2. Every pointer in `me/doctrine.source.md` resolves, and the template it names still hashes
#      to the digest recorded beside it. This is the freshness contract's "identity or refuse"
#      applied to a pointer: the target existing is not enough, it must be the SAME target.
#   3. Every copied guard still matches the live original recorded in its `guards/SOURCES`.
#      §5.2 step 2 copies deliberately, and a deliberate copy with no drift check is exactly how
#      `claude-orchestration-kit` ended up shipping an isolation guard at 37% of the current one.
#   4. Every `guards/settings.json` fragment is valid JSON and names only paths that exist.
#
# EXIT
#   0  every check passed
#   1  at least one check FAILED — the output names which, and what would fix it

set -uo pipefail

MYRICHOS_ROOT="${MYRICHOS_ROOT:-$HOME/myrichos}"

fail=0
note() { printf '  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
ok() { printf 'ok    %s\n' "$1"; }

printf 'checking %s\n\n' "$MYRICHOS_ROOT"

# --- 1. the shape ----------------------------------------------------------------------------
if [ ! -d "$MYRICHOS_ROOT" ]; then
    bad "the folder does not exist"
    note "fix: tools/myrichos/build-myrichos.sh"
    exit 1
fi

for d in me registry inbox companies; do
    if [ -d "$MYRICHOS_ROOT/$d" ]; then ok "$d/"; else bad "$d/ is missing"; fi
done

for c in femcboost deeply prospects richos gpt-exporter webinar-booster; do
    if [ -f "$MYRICHOS_ROOT/companies/$c/company.md" ]; then
        ok "companies/$c/company.md"
    else
        bad "companies/$c/company.md is missing"
    fi
done

# --- 2. the doctrine pointer -----------------------------------------------------------------
# The person-layer template is NOT copied here. It is version-controlled at the path named
# below and rendered by `doctrine.rs`. This folder holds a pointer to it, and the pointer
# carries the template's digest so a silent change is a failure rather than a surprise.
POINTER="$MYRICHOS_ROOT/me/doctrine.source.md"
if [ ! -f "$POINTER" ]; then
    bad "me/doctrine.source.md is missing"
else
    target="$(sed -n 's/^canonical: *//p' "$POINTER" | head -1)"
    digest="$(sed -n 's/^canonical-sha256: *//p' "$POINTER" | head -1)"
    if [ -z "$target" ] || [ -z "$digest" ]; then
        bad "me/doctrine.source.md carries no canonical/canonical-sha256 pair"
    elif [ ! -f "$target" ]; then
        bad "me/doctrine.source.md points at a target that does not exist: $target"
        note "this is the dangling-corpus failure. The pointer is wrong, or the repository moved."
    else
        actual="$(shasum -a 256 "$target" | cut -d' ' -f1)"
        if [ "$actual" = "$digest" ]; then
            ok "me/doctrine.source.md -> $target (digest matches)"
        else
            bad "the person-layer template CHANGED since this pointer was written"
            note "recorded: $digest"
            note "actual:   $actual"
            note "fix: confirm the change was intended, then update canonical-sha256 in $POINTER"
        fi
    fi
fi

# --- 3. copied-guard drift -------------------------------------------------------------------
for c in femcboost deeply prospects richos gpt-exporter webinar-booster; do
    sources="$MYRICHOS_ROOT/companies/$c/guards/SOURCES"
    [ -f "$sources" ] || continue
    while read -r recorded name origin; do
        [ -n "${recorded:-}" ] || continue
        copy="$MYRICHOS_ROOT/companies/$c/guards/$name"
        if [ ! -f "$copy" ]; then
            bad "$c: SOURCES records $name but the copy is gone"
            continue
        fi
        if [ ! -f "$origin" ]; then
            bad "$c/$name: the original is gone from $origin"
            note "the copy here is now the only copy, and nothing can check it"
            continue
        fi
        origin_now="$(shasum -a 256 "$origin" | cut -d' ' -f1)"
        copy_now="$(shasum -a 256 "$copy" | cut -d' ' -f1)"
        if [ "$origin_now" != "$recorded" ]; then
            bad "$c/$name: the ORIGINAL changed since it was copied"
            note "fix: re-copy it, or finish §5.2 step 6 and delete the original"
        elif [ "$copy_now" != "$recorded" ]; then
            bad "$c/$name: the COPY here was edited and no longer matches the original"
        else
            ok "$c/$name (matches original)"
        fi
    done < "$sources"
done

# --- 4. the fragments ------------------------------------------------------------------------
for c in femcboost deeply prospects richos gpt-exporter webinar-booster; do
    frag="$MYRICHOS_ROOT/companies/$c/guards/settings.json"
    if [ ! -f "$frag" ]; then
        bad "companies/$c/guards/settings.json is missing"
        continue
    fi
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$frag" 2>/dev/null; then
        bad "companies/$c/guards/settings.json is not valid JSON"
        continue
    fi
    # Every hook command in a fragment must be an absolute path that exists. A fragment is
    # delivered by `--settings` at spawn, where a path that does not resolve is a guard that
    # silently does not run — the failure this whole design is moving away from.
    missing=0
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        case "$cmd" in
            /*) [ -x "$cmd" ] || { bad "$c: fragment names a hook that is not executable: $cmd"; missing=1; } ;;
        esac
    done < <(python3 - "$frag" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for entries in d.get("hooks", {}).values():
    for entry in entries:
        for h in entry.get("hooks", []):
            print(h.get("command", "").split()[0] if h.get("command", "").startswith("/") else "")
PY
    )
    [ "$missing" -eq 0 ] && ok "companies/$c/guards/settings.json"
done

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'PASS — every pointer resolves and every copy matches its original.\n'
else
    printf 'FAILED — see the lines marked FAIL above.\n'
fi
exit "$fail"
