#!/usr/bin/env bash
#
# guard-interactive-prompt.test.sh — tests for the PreToolUse[Bash] guard that
# refuses commands which can stop and wait for a human.
#
# TWO-SIDED, EVERYWHERE, AND THAT IS THE POINT OF THE FILE.
# On 2026-08-31 probe Layer K sat green for as long as it had existed over a
# secrets scanner that never ran, because "caught a secret" and "could not
# start" were both exit 2. Every catching case in this suite is therefore
# paired: a prompting command is REFUSED, and a command that differs only by
# the fix is ALLOWED. A dead hook fails the first half; a hook that blocks
# everything fails the second. Neither can be green here.
#
#   A.  the measured incident, both sides
#   B.  every blocking shape fires
#   C.  every blocking shape's FIX makes it pass — the second half of A
#   D.  the report tier reports and does NOT block
#   E.  ordinary commands pass (the false-positive floor, drawn from the
#       real transcript corpus)
#   F.  the parser: heredoc bodies, quoting, comments, function definitions,
#       command substitution, wrappers, git global options
#   G.  fail-closed: no python3, no analyzer library
#   H.  jurisdiction: non-Bash passes, unadopted repository stands down
#   I.  the refusal NAMES THE FIX — a refusal that does not is worked around
#
# Run directly: scripts/hooks/guard-interactive-prompt.test.sh
# Exit 0 = all pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Declare the subject, for the reason every other hook suite does: run from a
# session seated elsewhere, the guard would resolve THAT repository, find no
# adoption marker, stand down, and every case below would pass by never running.
RICHOS_ENTITY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

HOOK="$SCRIPT_DIR/guard-interactive-prompt.sh"
BASH_BIN="$(command -v bash)"
ENGINE="$RICHOS_ENTITY_ROOT"

PASS=0
FAIL=0

[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing or not executable" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

SANDBOX="$(mktemp -d -t guard-interactive-prompt.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

payload() { # <command>
    COMMAND_UNDER_TEST="$1" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "cwd": os.environ["RICHOS_ENTITY_ROOT"],
                  "tool_input": {"command": os.environ["COMMAND_UNDER_TEST"]}}))'
}

# run <command> -> sets RC and OUT
run() {
    OUT="$(payload "$1" | "$BASH_BIN" "$HOOK" 2>&1)"
    RC=$?
}

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; printf '          %s\n' "${2:-}"; FAIL=$((FAIL + 1)); }

# blocked <case> <command>
blocked() {
    run "$2"
    if [ "$RC" -eq 2 ]; then ok "$1"; else bad "$1" "expected exit 2, got $RC: ${OUT:0:180}"; fi
}
# allowed <case> <command> — exit 0 AND COMPLETELY SILENT.
#
# Silence, not merely "no BLOCKED banner". The weaker form let an over-blocking
# mutation through: turning every `git commit -m ...` into a report still exits
# 0 and prints no banner, so the suite stayed green over a guard that had begun
# complaining about correct commands. Found by
# scripts/hooks/interactive-prompt.mutation.sh, which is what it is for.
allowed() {
    run "$2"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
        ok "$1"
    else
        bad "$1" "expected a clean, SILENT exit 0, got $RC: ${OUT:0:180}"
    fi
}
# reported <case> <command> — exit 0 AND a NOTE on stderr
reported() {
    run "$2"
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'guard-interactive-prompt) NOTE'; then
        ok "$1"
    else
        bad "$1" "expected exit 0 with a NOTE, got $RC: ${OUT:0:180}"
    fi
}

echo "=== A. THE MEASURED INCIDENT, BOTH SIDES ==="
# The command that put a window on the CEO's screen at 02:01 on 2026-09-01.
INCIDENT="security import D.p12 -k $SANDBOX/t3.keychain-db -T /usr/bin/codesign"
blocked "A1. the 02:01 command is refused" "$INCIDENT"
run "$INCIDENT"
if printf '%s' "$OUT" | grep -qF -- "-P"; then
    ok "A2. the refusal NAMES -P, which is the whole fix"
else
    bad "A2. the refusal names -P" "no -P in: ${OUT:0:300}"
fi
if printf '%s' "$OUT" | grep -qF "02:01"; then
    ok "A3. the refusal cites the incident, so nobody re-litigates it"
else
    bad "A3. the refusal cites the incident" "${OUT:0:300}"
fi
# THE SECOND HALF. A dead hook passes A1 by exiting 2 for any reason at all;
# it cannot pass this, because this asserts a SPECIFIC command runs.
allowed "A4. the same command WITH -P '' is allowed (the canary a dead hook fails)" \
    "security import D.p12 -k $SANDBOX/t3.keychain-db -P '' -T /usr/bin/codesign"

echo ""
echo "=== B. EVERY BLOCKING SHAPE FIRES ==="
blocked "B1.  security import, no -P"                "security import a.p12 -k login.keychain-db"
blocked "B2.  security import via an absolute path"  "/usr/bin/security import a.p12 -k login.keychain-db"
blocked "B3.  security unlock-keychain, no -p"       "security unlock-keychain build.keychain"
blocked "B4.  security create-keychain, no -p"       "security create-keychain build.keychain"
blocked "B5.  security set-key-partition-list, no -k" "security set-key-partition-list -S apple-tool:,apple: -s build.keychain"
blocked "B6.  security add-generic-password, no -w"  "security add-generic-password -a me -s svc"
blocked "B7.  sudo, no -n"                           "sudo sqlite3 /Library/x.db 'select 1'"
blocked "B8.  sudo -k (a flag that is not -n)"       "echo hi && sudo -k true"
blocked "B9.  ssh, no BatchMode"                     "ssh alex@host uptime"
blocked "B10. scp, no BatchMode"                     "scp f.txt alex@host:/tmp/"
blocked "B11. sftp, no BatchMode"                    "sftp alex@host"
blocked "B12. ssh-add of a key"                      "ssh-add ~/.ssh/id_ed25519"
blocked "B13. osascript display dialog"              "osascript -e 'display dialog \"Enter the password\"'"
blocked "B14. osascript with administrator privileges" "osascript -e 'do shell script \"id\" with administrator privileges'"
blocked "B15. osascript choose file"                 "osascript -e 'choose file with prompt \"pick\"'"
blocked "B16. git rebase -i"                         "git rebase -i HEAD~3"
blocked "B17. git rebase --interactive"              "git rebase --interactive main"
blocked "B18. git mergetool"                         "git mergetool"
blocked "B19. git config --edit"                     "git config --edit"
blocked "B20. crontab -e"                            "crontab -e"
blocked "B21. vim"                                   "vim /etc/hosts"
blocked "B22. nano"                                  "nano notes.txt"
blocked "B23. htop"                                  "htop"
blocked "B24. bare top"                              "top"
blocked "B25. open -W"                               "open -W /Applications/Preview.app"
blocked "B26. gh auth login"                         "gh auth login"
blocked "B27. npm login"                             "npm login"
blocked "B28. docker login, no --password-stdin"     "docker login ghcr.io -u me"
blocked "B29. railway login"                         "railway login"
blocked "B30. aws configure"                         "aws configure"
blocked "B31. gcloud auth login"                     "gcloud auth login"
blocked "B32. az login"                              "az login"
blocked "B33. apt-get install, no -y"                "apt-get install curl"
blocked "B34. ssh-keygen generating, no -N"          "ssh-keygen -t ed25519 -f $SANDBOX/k"
blocked "B35. ssh-keygen -p, no -N"                  "ssh-keygen -p -f $SANDBOX/k"
blocked "B36. notarytool store-credentials, no --password" \
    "xcrun notarytool store-credentials profile --apple-id me@example.com"
# The sudo-as-wrapper case: the inner command is still judged.
blocked "B37. sudo -n hides the sudo shape but not the inner one" \
    "sudo -n security import a.p12 -k login.keychain-db"
blocked "B38. inside command substitution"           "RESULT=\$(sudo whoami)"
blocked "B39. inside a for-loop body"                "for f in a b; do sudo rm \$f; done"
blocked "B40. behind timeout and an assignment"      "X=1 timeout 30 sudo /usr/bin/true"

echo ""
echo "=== C. THE FIX MAKES IT PASS — the other side of every shape above ==="
allowed "C1.  security import -P ''"                 "security import a.p12 -k login.keychain-db -P ''"
allowed "C2.  security unlock-keychain -p"           "security unlock-keychain -p 'pw' build.keychain"
allowed "C3.  security set-key-partition-list -k"    "security set-key-partition-list -S apple-tool:,apple: -s -k 'pw' build.keychain"
allowed "C4.  security add-generic-password -w"      "security add-generic-password -a me -s svc -w 'secret'"
allowed "C5.  sudo -n"                               "sudo -n sqlite3 /Library/x.db 'select 1'"
allowed "C6.  sudo --non-interactive"                "sudo --non-interactive true"
allowed "C7.  ssh -o BatchMode=yes"                  "ssh -o BatchMode=yes alex@host uptime"
allowed "C8.  ssh -o \"BatchMode=yes\" (quoted exemption still counts)" \
    "ssh -o \"BatchMode=yes\" alex@host uptime"
allowed "C9.  ssh-add -l is a listing"               "ssh-add -l"
allowed "C10. osascript with no dialog verb"         "osascript -e 'output volume of (get volume settings)'"
allowed "C11. osascript display notification"        "osascript -e 'display notification \"done\"'"
allowed "C12. git rebase without -i"                 "git rebase --onto main abc123"
allowed "C13. crontab from a file"                   "crontab $SANDBOX/jobs"
allowed "C14. top -l 1"                              "top -l 1"
allowed "C15. open without -W"                       "open /Applications/Preview.app"
allowed "C16. gh auth login --with-token"            "gh auth login --with-token"
allowed "C17. gh auth status is not a login"         "gh auth status"
allowed "C18. docker login --password-stdin"         "docker login ghcr.io -u me --password-stdin"
allowed "C19. aws configure set"                     "aws configure set region us-east-1"
allowed "C20. apt-get install -y"                    "apt-get install -y curl"
allowed "C21. ssh-keygen -N ''"                      "ssh-keygen -t ed25519 -N '' -f $SANDBOX/k"
allowed "C22. notarytool with --password"            "xcrun notarytool store-credentials p --apple-id me@example.com --password 'x'"
allowed "C23. security find-identity is a read"      "security find-identity -v -p codesigning"

echo ""
echo "=== D. THE REPORT TIER REPORTS, AND DOES NOT BLOCK ==="
reported "D1. git commit with no message flag"       "git commit"
reported "D2. git -C <path> commit --amend (global options do not hide it)" \
    "git -C /repo commit --amend"
reported "D3. git add -p"                            "git add -p file.py"
reported "D4. codesign with a real identity"         "codesign --force --sign 'Developer ID Application: X (Y)' /tmp/A.app"
reported "D5. openssl req generating a key"          "openssl req -newkey rsa:2048 -keyout k.pem -out c.csr"
run "git commit"
if printf '%s' "$OUT" | grep -qF -- "-m"; then
    ok "D6. the report names the fix too, not only the block"
else
    bad "D6. the report names the fix" "${OUT:0:220}"
fi
allowed "D7. git commit -m is clean"                 "git commit -m 'a change'"
allowed "D8. git commit -qm bundled short flags"     "git commit -qm 'a change'"
allowed "D9. git commit -F -"                        "git commit -q -F -"
allowed "D10. git commit --amend --no-edit"          "git commit --amend --no-edit"
allowed "D11. codesign --sign - is ad-hoc"           "codesign --force --sign - /tmp/A.app"
allowed "D12. codesign -dvvv is a read"              "codesign -dvvv /tmp/A.app"
allowed "D13. openssl req -nodes"                    "openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem"
allowed "D14. openssl req verifying a CSR"           "openssl req -in c.csr -noout -verify -subject"

echo ""
echo "=== E. THE FALSE-POSITIVE FLOOR — real commands from the transcript corpus ==="
# Every one of these is a VERBATIM shape from the 65,781-command corpus
# scripts/hooks/interactive-prompt.corpus.md measures against. They are here
# because a guard is only as good as the day it stops being trusted.
allowed "E1.  a plain git log"          "git -C /Users/alex/ab/richos log --oneline -8"
allowed "E2.  grep for the word sudo"   "grep -rn 'sudo' docs/ | head -20"
allowed "E3.  echo naming a shape"      "echo 'security import needs -P'"
# E3b/E3c are what the quote MASKING defends, as opposed to command-position
# matching. A separator inside a quoted string is not a separator: without the
# masking, the `;` in a commit message splits the line and the words after it
# are read as a command. Commit messages here routinely quote shell commands.
allowed "E3b. a commit message quoting shell commands" \
    "git commit -m 'first: sudo apt-get install x; then ssh host uptime'"
allowed "E3c. an echo containing a separator and a program name" \
    "echo \"done; vim /tmp/f\""
allowed "E4.  a merge and a status"     "git merge --no-ff branch 2>&1 | tail -4; git status --short"
allowed "E5.  cherry-pick"              "git cherry-pick c3fe10e 2>&1 | tail -2"
allowed "E6.  a python heredoc"         "$(printf 'cd /x && python3 - <<PY\nimport os\n# sudo is mentioned here\nprint("security import x")\nPY\n')"
allowed "E7.  writing a shell script"   "$(printf 'cat > /tmp/s.sh <<EOF\n#!/bin/bash\nsudo rm -rf /x\nssh host uptime\nEOF\n')"
allowed "E8.  a helper function named ed" \
    "$(printf 'cd /x\ned() { python3 -c "import sys"; }\ned a b\n')"
# E8b is the one the funcdef blanking is actually load-bearing for. `ed` was
# dropped from the shape table once the corpus showed 40 hits from a single
# engineer's helper, so E8 is now defended twice over; a wrapper named after a
# program that IS in the table is the case that still needs the parser.
allowed "E8b. a helper function named after an interactive program" \
    "$(printf 'top() { /usr/bin/top -l 1 \"\$@\"; }\ntop -l 1\n')"
allowed "E9.  find with -name"          "find . -name '*.tmp' | head"
allowed "E10. a commented-out command"  "$(printf 'ls -la\n# sudo rm -rf /\n')"
allowed "E11. ssh mentioned as a path"  "ls packages/ssh/src && gh config set git_protocol ssh"
allowed "E12. codesign display only"    "codesign -dvvv /tmp/A.app 2>&1 | head -4"
allowed "E13. a scratchpad heredoc carrying a full guard" \
    "$(printf 'cat > /tmp/g.sh <<GUARD_EOF\n#!/usr/bin/env bash\n# security import without -P draws a window\nsudo -k true\nGUARD_EOF\n')"
allowed "E14. install-fresh style pipeline" \
    "bash scripts/android-install-fresh.sh --sha abc123 2>&1 | tail -20"
allowed "E15. the deploy script"        "scripts/deploy-avelor-staging.sh 2>&1 | tail -5"

echo ""
echo "=== F. THE PARSER ==="
allowed "F1. a here-STRING is not a heredoc"  "grep x <<< 'sudo rm'"
blocked "F2. a real command AFTER a heredoc is still judged" \
    "$(printf 'cat > /tmp/a.txt <<EOF\nsudo nothing\nEOF\nsudo whoami\n')"
blocked "F3. after a pipe"                    "echo x | sudo tee /etc/hosts"
blocked "F4. after &&"                        "cd /tmp && sudo true"
blocked "F5. in a subshell"                   "(cd /tmp; sudo true)"
allowed "F6. a masked command name is not guessed" "\"\$CMD\" import a.p12"
allowed "F7. an unquoted apostrophe does not derail the scan" "echo it is fine"

echo ""
echo "=== G. FAIL-CLOSED ==="
FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
for b in cat sed grep awk printf env test true false head tr cut sort uniq wc dirname basename mktemp rm chmod ls date shasum; do
    src="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$FAKEBIN/$b"
done
NOPY_OUT="$(payload "ls" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" 2>&1)"; NOPY_RC=$?
if [ "$NOPY_RC" -eq 2 ] && printf '%s' "$NOPY_OUT" | grep -qF 'python3'; then
    ok "G1. no python3 -> exit 2, naming python3"
else
    bad "G1. no python3 -> fail-closed" "got exit $NOPY_RC: ${NOPY_OUT:0:200}"
fi

# The analyzer library removed. This is the case scripts/lib/sandbox-
# completeness.sh reads: the hook must ANNOUNCE what is missing, by name, or a
# sandbox that omits the file looks identical to one that carries it.
COPY="$SANDBOX/engine"
mkdir -p "$COPY/scripts/hooks" "$COPY/scripts/lib"
cp "$HOOK" "$COPY/scripts/hooks/"
cp "$ENGINE/scripts/lib/resolve-roots.sh" "$COPY/scripts/lib/"
cp "$ENGINE/scripts/lib/resolve-main-checkout.sh" "$COPY/scripts/lib/" 2>/dev/null || true
cp "$ENGINE/orchestration.config" "$COPY/" 2>/dev/null || true
chmod +x "$COPY/scripts/hooks/guard-interactive-prompt.sh"
NOLIB_OUT="$(payload "ls" | RICHOS_ENTITY_ROOT="$COPY" "$BASH_BIN" "$COPY/scripts/hooks/guard-interactive-prompt.sh" 2>&1)"
NOLIB_RC=$?
if [ "$NOLIB_RC" -eq 2 ] && printf '%s' "$NOLIB_OUT" | grep -qF 'interactive-prompt.py is missing at:'; then
    ok "G2. no analyzer library -> exit 2, naming the missing file"
else
    bad "G2. no analyzer library -> fail-closed and named" "got exit $NOLIB_RC: ${NOLIB_OUT:0:220}"
fi
if printf '%s' "$NOLIB_OUT" | grep -qF 'BROKEN INSTALL'; then
    ok "G3. it uses the shared BROKEN INSTALL banner the completeness check reads"
else
    bad "G3. the shared banner" "${NOLIB_OUT:0:220}"
fi

echo ""
echo "=== H. JURISDICTION ==="
NONBASH="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"/tmp/x","content":"sudo rm"}}' "$ENGINE" | "$BASH_BIN" "$HOOK" 2>&1)"; NB_RC=$?
if [ "$NB_RC" -eq 0 ]; then ok "H1. a non-Bash tool passes"; else bad "H1. non-Bash passes" "exit $NB_RC: ${NONBASH:0:160}"; fi

# NOT-ADOPTED, not BROKEN, and the difference is the case. An EXPLICIT
# RICHOS_ENTITY_ROOT pointing at a directory with no orchestration.config is
# `broken` — the session declared a root the engine cannot govern, and a guard
# that believes it is governing something must never guess. `not-adopted` is
# the different thing: nothing was declared, and the payload's own cwd simply
# never adopted. That stands down.
UNADOPTED="$SANDBOX/unadopted"
mkdir -p "$UNADOPTED"
UA_PAYLOAD="$(COMMAND_UNDER_TEST="sudo rm -rf /" UA_DIR="$UNADOPTED" python3 -c '
import json, os
print(json.dumps({"tool_name": "Bash", "cwd": os.environ["UA_DIR"],
                  "tool_input": {"command": os.environ["COMMAND_UNDER_TEST"]}}))')"
UA_OUT="$(cd "$UNADOPTED" && printf '%s' "$UA_PAYLOAD" | env -u RICHOS_ENTITY_ROOT -u CLAUDE_PROJECT_DIR "$BASH_BIN" "$HOOK" 2>&1)"; UA_RC=$?
if [ "$UA_RC" -eq 0 ]; then
    ok "H2. a repository that never adopted the engine stands down"
else
    bad "H2. unadopted stands down" "exit $UA_RC: ${UA_OUT:0:200}"
fi
UB_OUT="$(payload "sudo rm -rf /" | RICHOS_ENTITY_ROOT="$UNADOPTED" "$BASH_BIN" "$HOOK" 2>&1)"; UB_RC=$?
if [ "$UB_RC" -eq 2 ] && printf '%s' "$UB_OUT" | grep -qF 'ROOT RESOLUTION FAILURE'; then
    ok "H3. a DECLARED root the engine cannot govern is broken, and blocks"
else
    bad "H3. a declared ungovernable root blocks" "exit $UB_RC: ${UB_OUT:0:200}"
fi

echo ""
echo "=== I. EVERY BLOCKING REFUSAL NAMES A FIX ==="
# A refusal without a remedy is a refusal that gets worked around. This walks
# one command per blocking shape and asserts the word FIX and a non-empty
# remedy reach stderr — the property, not one message's wording.
NOFIX=""
while IFS= read -r c; do
    [ -n "$c" ] || continue
    run "$c"
    printf '%s' "$OUT" | grep -q 'FIX: .' || NOFIX="$NOFIX|$c"
done <<'CASES'
security import a.p12 -k login.keychain-db
sudo whoami
ssh alex@host uptime
ssh-add /tmp/k
osascript -e 'display dialog "x"'
git rebase -i HEAD~2
crontab -e
vim /tmp/f
top
open -W /Applications/Preview.app
gh auth login
npm login
apt-get install curl
ssh-keygen -t rsa -f /tmp/k
CASES
if [ -z "$NOFIX" ]; then
    ok "I1. every blocking shape's refusal carries a named FIX"
else
    bad "I1. every blocking refusal names a fix" "no FIX for:${NOFIX}"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== guard-interactive-prompt tests: $FAIL FAILED, $PASS passed ==="
    exit 1
else
    echo "=== guard-interactive-prompt tests: all $PASS passed ==="
    exit 0
fi
