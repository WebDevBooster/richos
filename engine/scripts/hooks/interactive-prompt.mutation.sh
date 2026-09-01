#!/usr/bin/env bash
#
# interactive-prompt.mutation.sh — PROVES THE INTERACTIVE-PROMPT SUITE CAN FAIL.
#
# 111 green ticks are evidence of nothing until somebody watches them go red for
# the right reason. This guard has a particularly cheap way of looking healthy
# while doing nothing: it is wired, hashed, present, executable, and its
# blocking cases assert EXIT 2 — which is also what it exits when it cannot
# start at all. That is precisely the confusion that left probe Layer K green
# for weeks over a secrets scanner that never ran, on 2026-08-31.
#
# So: take the SHIPPED source, remove ONE property at a time, and assert
#   1. guard-interactive-prompt.test.sh FAILS,
#   2. the SPECIFIC named case fails — not merely "something went red", and
#   3. the mutation actually applied (a replacement matching nothing produces a
#      green run that looks exactly like a green run, which is the same trap
#      one level up).
#
# Note what half the mutants below are FOR. Four of them (over-block-*) do not
# weaken the guard at all — they make it STRICTER, and the suite must go red
# anyway. A guard that blocks too much is not a safe failure here: it is the
# failure that gets it waived, and then switched off. The two-sided cases in the
# suite are what make that assertion possible.
#
# ===========================================================================
# WHY EVERY PATCH ARRIVES ON STDIN AND NEVER AS A SHELL ARGUMENT
# ===========================================================================
# The first draft of this file passed each mutation as a quoted argument, with
# a human-readable reason beside it. Two of those reasons named a command in
# backticks — the ordinary way to quote a command in prose — and the shell
# EXECUTED THEM. `sudo -n` and `ssh -o BatchMode=yes` both ran, out of a file
# whose entire subject is commands that must not run unsupervised. They printed
# a usage message and nothing worse, because the fix this guard recommends is
# also the safe one. The mutation text fared no better: backslashes in a regex
# were mangled through three layers of quoting and four mutants silently failed
# to apply.
#
# So the patches come in through a single-quoted heredoc, which the shell does
# not interpret at all, and are matched byte-for-byte. Nothing in this file is
# evaluated by a shell except the file paths.
#
# Every mutant is a throwaway copy of the engine subtree. Nothing here touches
# the real tree.
#
# Run directly: scripts/hooks/interactive-prompt.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t interactive-prompt-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

# Reads a patch on stdin as:  <<<OLD\n...\n>>>NEW\n...\n  and applies it once.
cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path = sys.argv[1]
spec = sys.stdin.read()
if "<<<OLD\n" not in spec or "\n>>>NEW\n" not in spec:
    sys.stderr.write("malformed patch spec\n"); sys.exit(4)
old = spec.split("<<<OLD\n", 1)[1].split("\n>>>NEW\n", 1)[0]
new = spec.split("\n>>>NEW\n", 1)[1]
if new.endswith("\n"):
    new = new[:-1]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n")
    sys.stderr.write("\n".join("    " + l for l in old.split("\n")) + "\n")
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# mutant <name> <expected-failing-case> <rel-file> <why>  [patch on stdin]
mutant() {
    local name="$1" want="$2" rel="$3" why="$4"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/scripts/hooks/guard-interactive-prompt.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-interactive-prompt.test.sh" "$dir/scripts/hooks/"
    cp "$ENGINE_ROOT/scripts/lib/interactive-prompt.py" \
       "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" \
       "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$dir/scripts/lib/"
    cp "$ENGINE_ROOT/orchestration.config" "$dir/"
    chmod +x "$dir/scripts/hooks/"*.sh "$dir/scripts/lib/interactive-prompt.py"

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        FAIL=$((FAIL + 1)); return
    fi

    ( cd "$dir" && bash "$dir/scripts/hooks/guard-interactive-prompt.test.sh" ) >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        FAIL=$((FAIL + 1)); return
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | head -5 | sed 's/^/          /'
        FAIL=$((FAIL + 1)); return
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    PASS=$((PASS + 1))
}

echo "=== the interactive-prompt guard: every property, proven by removing it ==="

H="scripts/hooks/guard-interactive-prompt.sh"
L="scripts/lib/interactive-prompt.py"

# --- 1. IT REFUSES AT ALL --------------------------------------------------
mutant refuses-to-refuse "A1. " "$H" \
  'the guard would find the prompting command, print the whole refusal, and let it through anyway - a warning wearing a guard clothes, and the screen unchanged.' <<'PATCH'
<<<OLD
        echo "(hook: scripts/hooks/guard-interactive-prompt.sh)"
    } >&2
    exit 2 ;;
>>>NEW
        echo "(hook: scripts/hooks/guard-interactive-prompt.sh)"
    } >&2
    exit 0 ;;
PATCH

# --- 2. THE MEASURED SHAPE IS WHAT DECIDES ---------------------------------
mutant no-security-import-rule "A1. " "$L" \
  'the 02:01 command itself would pass. This is the one line the whole row exists for.' <<'PATCH'
<<<OLD
        if sub == "import" and not _short(ut, "P"):
>>>NEW
        if False and sub == "import" and not _short(ut, "P"):
PATCH

# --- 3. THE EXEMPTION MUST WORK — over-blocking is a failure, not a safety --
mutant over-block-security-import "A4. " "$L" \
  'every security import would be refused INCLUDING the corrected one, so the named fix would not work and the only remaining move on the day is to waive the guard.' <<'PATCH'
<<<OLD
        if sub == "import" and not _short(ut, "P"):
>>>NEW
        if sub == "import" and True:
PATCH

mutant over-block-sudo "C5. " "$L" \
  'sudo with -n, the fix this guard tells people to use, would be refused too.' <<'PATCH'
<<<OLD
            if not (_short(own, "n") or _long(own, "--non-interactive")):
>>>NEW
            if True:
PATCH

mutant over-block-ssh "C7. " "$L" \
  'ssh with BatchMode=yes would be refused, so the remedy named in the refusal would be a lie.' <<'PATCH'
<<<OLD
        if not re.search(r"(?i)batchmode\s*=\s*yes", unq_joined):
>>>NEW
        if True:
PATCH

mutant over-block-git-commit "D7. " "$L" \
  'a commit that already carries -m would be reported at anyway, and a guard that complains about correct commands is one people learn to read past.' <<'PATCH'
<<<OLD
            if not (_short(rest_u, "mFC")
                    or _long(rest_u, "--message", "--file", "--no-edit", "--reuse-message",
                             "--reedit-message", "--fixup", "--squash", "--template")):
>>>NEW
            if True:
PATCH

# --- 4. HEREDOC BODIES ARE DATA, NOT COMMANDS ------------------------------
mutant no-heredoc-stripping "E7. " "$L" \
  'every cat-into-a-file heredoc carrying a shell script would be judged as if the script were being RUN, which is most of how files are written here and would make this guard unusable within a day.' <<'PATCH'
<<<OLD
_HEREDOC_OPEN = re.compile(r"<<(-?)\s*(?![<])(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
>>>NEW
_HEREDOC_OPEN = re.compile(r"(?!x)x")
PATCH

# --- 5. QUOTED TEXT MUST NOT ACCUSE ----------------------------------------
# E3b, NOT E2, and the difference is a finding this harness produced rather than
# confirmed. `grep -rn 'sudo' docs/` survives with the masking removed, because
# command-POSITION matching already defends it: sudo there is an argument, not a
# command word. What the masking alone defends is a SEPARATOR inside a quoted
# string — the `;` in a commit message that quotes a shell command, which splits
# the line and turns the words after it into a command.
mutant no-quote-masking "E3b." "$L" \
  'a separator inside a quoted commit message would split the line, and the words after it would be judged as a command.' <<'PATCH'
<<<OLD
            if c in "'\"":
                state = c
>>>NEW
            if False:
                state = c
PATCH

# --- 6. A FUNCTION DEFINITION IS NOT A COMMAND -----------------------------
mutant no-funcdef-blanking "E8b." "$L" \
  'a shell helper function whose name happens to be an interactive program would be read as an invocation of it - 40 false positives in the measured corpus, all from one engineer helper function.' <<'PATCH'
<<<OLD
    for m in _FUNCDEF.finditer(masked):
>>>NEW
    for m in ():
PATCH

# --- 7. GIT'S GLOBAL OPTIONS MUST NOT HIDE THE SUBCOMMAND ------------------
mutant no-git-global-parsing "D2. " "$L" \
  'git -C <path> commit would read as a repository named <path>, and every git command in this project is written that way - the guard would be silently blind to all of them.' <<'PATCH'
<<<OLD
        sub, gj = git_sub(mt, i)
>>>NEW
        sub, gj = _sub(mt, i), i
PATCH

# --- 8. FAIL-CLOSED WHEN THE JUDGMENT IS GONE ------------------------------
mutant analyzer-missing-passes "G2. " "$H" \
  'a sandbox or an install that lost the analyzer library would run with this guard silently inert, which is the exact defect scripts/lib/sandbox-completeness.sh was built to catch.' <<'PATCH'
<<<OLD
        echo "  Refusing rather than passing every command through unjudged."
    } >&2
    exit 2
fi

INPUT="$(cat)"
>>>NEW
        echo "  Refusing rather than passing every command through unjudged."
    } >&2
    exit 0
fi

INPUT="$(cat)"
PATCH

# --- 9. THE REFUSAL MUST NAME THE FIX --------------------------------------
mutant refusal-without-fix "I1. " "$H" \
  'a refusal with no remedy is a refusal that gets routed around, and a guard routed around often enough is a guard somebody turns off.' <<'PATCH'
<<<OLD
    sys.stdout.write("  * %s (%s)\n      why: %s\n      FIX: %s\n"
                     % (f["token"], f["shape"], f["why"], f["fix"]))
>>>NEW
    sys.stdout.write("  * %s (%s)\n      why: %s\n"
                     % (f["token"], f["shape"], f["why"]))
PATCH

# --- 10. THE REPORT TIER MUST NOT BLOCK ------------------------------------
mutant report-tier-blocks "D1. " "$L" \
  'every messageless git commit would be REFUSED on a hazard that depends on the editor setting - the guard would start being wrong about something people do daily, which is how a defense becomes a formality.' <<'PATCH'
<<<OLD
                    "editor fails in a second, a windowed one waits all night.",
                    severity="report")
>>>NEW
                    "editor fails in a second, a windowed one waits all night.")
PATCH

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== interactive-prompt mutations: $FAIL FAILED, $PASS proven load-bearing ==="
    exit 1
else
    echo "=== interactive-prompt mutations: all $PASS properties proven load-bearing ==="
    exit 0
fi
