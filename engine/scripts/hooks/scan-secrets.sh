#!/usr/bin/env bash
#
# scan-secrets.sh — PreToolUse guard (Write|Edit|MultiEdit|NotebookEdit).
#
# Closes the "will these autonomous agents leak my credentials into a commit?"
# objection — a top-three security question from any CEO evaluating an
# autonomous-agent team. Scans the CONTENT a Write/Edit/MultiEdit/NotebookEdit
# tool call is about to introduce for secret-shaped strings, and BLOCKS the
# write before it ever reaches disk — structurally, not by promise. This is
# the same "catch it at the moment of the write" posture as
# guard-main-checkout-writes.sh; it is wired as a SECOND hook under that same
# PreToolUse[Write|Edit|MultiEdit|NotebookEdit] matcher (see
# .claude/settings.local.json), not a separate git pre-commit hook — the engine
# has zero git-hook infrastructure today, and this slots into the existing
# Claude-Code-hook framework with no new installation mechanism, per the
# roadmap's own "no new infrastructure" constraint.
#
# WHAT IT CATCHES (two independent detector classes):
#
#   1. Vendor-prefix patterns — high-confidence because the prefix already
#      narrows the false-positive space enormously: AWS access keys
#      (AKIA/ASIA...), GitHub tokens (ghp_/gho_/ghu_/ghs_/ghr_/github_pat_...),
#      OpenAI keys (sk-.../sk-proj-...), Anthropic keys (sk-ant-...), Stripe
#      LIVE keys (sk_live_/pk_live_/rk_live_ — test-mode sk_test_/pk_test_
#      keys are deliberately NOT flagged, matching common practice for
#      non-production fixtures), and PEM private-key blocks
#      (-----BEGIN ... PRIVATE KEY-----).
#   2. Generic key=value literals — password=/passwd=/pwd=/api_key=/secret=/
#      token=/access_key=/private_key=, gated by Shannon entropy of the value
#      (real secrets are pseudo-random; placeholders are not) so a fixture
#      like `api_key = "re_xxxxxxxxx"` does NOT false-positive: a run of a
#      single repeated character has ~0 bits/char of entropy, far below the
#      real-secret threshold, so no allowlist entry is even required for that
#      specific shape — the entropy gate handles it structurally. Additional,
#      explicit exemptions: known placeholder words (placeholder, changeme,
#      example, dummy, redacted, ...), environment-variable-reference syntax
#      (${VAR}, process.env.X, os.environ[...], os.getenv(...) — the CORRECT
#      way to handle a real secret, never itself a leak), and
#      SECRET_SCAN_ALLOWLIST in orchestration.config (space-separated literal
#      substrings an adopter can add for their own known-safe fixtures).
#
# Findings are NEVER echoed in full in the block message — only a redacted
# preview (first few / last few characters) — so the block message itself
# never becomes a second place the secret leaks (terminal scrollback, CI
# logs).
#
# FAIL-CLOSED on a missing python3 (matches every other hook this session's
# audit hardened). FAILS OPEN (passes through, exit 0) on a malformed/
# unparseable JSON payload — matching guard-main-checkout-writes.sh's own
# convention for this same Write|Edit matcher class (a payload that can't be
# understood isn't itself a threat to react to; Agent-spawn guards fail
# closed on unparseable payloads because spawns are the harder security
# boundary — this hook follows its Write/Edit sibling's convention instead).

set -eo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: scan-secrets.sh: python3 is required for payload parsing — refusing (fail-closed)" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG="$REPO_ROOT/orchestration.config"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${SECRET_SCAN_MIN_LENGTH:=12}"
: "${SECRET_SCAN_MIN_ENTROPY:=3.0}"
: "${SECRET_SCAN_ALLOWLIST:=}"
# Exported so the python3 subprocess below (a separate process, not a bash
# child that inherits unexported shell variables) can actually see them —
# without this, config values loaded from orchestration.config would silently
# never reach the scanner.
export SECRET_SCAN_MIN_LENGTH SECRET_SCAN_MIN_ENTROPY SECRET_SCAN_ALLOWLIST

INPUT="$(cat)"

TOOL_NAME="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_name",""))' 2>/dev/null || true)"
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); ti=d.get("tool_input",{}) or {}; print(ti.get("file_path") or ti.get("notebook_path") or "")' 2>/dev/null || true)"

# The actual scan: extract every piece of NEW text this call would introduce
# (Write: content; Edit: new_string; MultiEdit: each edits[].new_string;
# NotebookEdit: new_source), then run both detector classes against it.
# Emits either "CLEAN" or "FOUND\n<label>\t<redacted-preview>\n..." on stdout.
SCAN_PY="$(mktemp -t scan-secrets.XXXXXX.py)"
trap 'rm -f "$SCAN_PY"' EXIT
cat >"$SCAN_PY" <<'PY'
import json, math, os, re, sys

ALLOWLIST = [a for a in os.environ.get("SECRET_SCAN_ALLOWLIST", "").split() if a]
MIN_LEN = int(os.environ.get("SECRET_SCAN_MIN_LENGTH", "12") or "12")
MIN_ENTROPY = float(os.environ.get("SECRET_SCAN_MIN_ENTROPY", "3.0") or "3.0")

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("PARSEFAIL")
    sys.exit(0)

if not isinstance(payload, dict):
    print("PARSEFAIL")
    sys.exit(0)

tool_name = payload.get("tool_name", "")
ti = payload.get("tool_input", {})
if not isinstance(ti, dict):
    ti = {}

texts = []
if tool_name == "Write":
    texts.append(ti.get("content") or "")
elif tool_name == "Edit":
    texts.append(ti.get("new_string") or "")
elif tool_name == "MultiEdit":
    for e in (ti.get("edits") or []):
        if isinstance(e, dict):
            texts.append(e.get("new_string") or "")
elif tool_name == "NotebookEdit":
    texts.append(ti.get("new_source") or "")

blob = "\n".join(t for t in texts if isinstance(t, str))

def shannon_entropy(s):
    if not s:
        return 0.0
    freq = {}
    for ch in s:
        freq[ch] = freq.get(ch, 0) + 1
    n = len(s)
    ent = 0.0
    for c in freq.values():
        p = c / n
        ent -= p * math.log2(p)
    return ent

PLACEHOLDER_WORDS = (
    "placeholder", "changeme", "change_me", "example", "dummy", "sample",
    "insert", "replace", "redacted", "notreal", "fake", "your_key",
    "yourkey", "your-key", "todo", "fixme", "test_only", "<your",
)

def is_placeholder(value):
    low = value.lower()
    if any(w in low for w in PLACEHOLDER_WORDS):
        return True
    # A run dominated by one or two distinct characters (e.g. "xxxxxxxxx",
    # "0000000000") is definitionally low-entropy — real secrets are not this.
    if len(value) >= 4 and len(set(value)) <= 2:
        return True
    # Environment-variable-reference syntax is the CORRECT way to handle a
    # secret, never itself a leak.
    if re.search(r'\$\{?[A-Z_][A-Z0-9_]*\}?', value):
        return True
    if 'process.env' in value or 'os.environ' in value or 'os.getenv' in value:
        return True
    for a in ALLOWLIST:
        if a in value:
            return True
    return False

def redact(value):
    if len(value) <= 10:
        return value[:2] + "…" + value[-1:] if len(value) > 3 else "…"
    return value[:5] + "…redacted…" + value[-3:]

FINDINGS = []

VENDOR_PATTERNS = [
    ("AWS access key",              re.compile(r'\b(AKIA|ASIA)[0-9A-Z]{16}\b')),
    ("GitHub token",                re.compile(r'\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b')),
    ("GitHub fine-grained PAT",     re.compile(r'\bgithub_pat_[A-Za-z0-9_]{22,}\b')),
    ("Anthropic API key",           re.compile(r'\bsk-ant-[A-Za-z0-9_-]{20,}\b')),
    ("OpenAI project API key",      re.compile(r'\bsk-proj-[A-Za-z0-9_-]{20,}\b')),
    ("OpenAI API key",              re.compile(r'\bsk-(?!ant-|proj-)[A-Za-z0-9]{20,}\b')),
    ("Stripe live secret key",      re.compile(r'\bsk_live_[A-Za-z0-9]{24,}\b')),
    ("Stripe live publishable key", re.compile(r'\bpk_live_[A-Za-z0-9]{24,}\b')),
    ("Stripe live restricted key",  re.compile(r'\brk_live_[A-Za-z0-9]{24,}\b')),
    ("PEM private key block",       re.compile(r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')),
]

for label, pattern in VENDOR_PATTERNS:
    for m in pattern.finditer(blob):
        matched = m.group(0)
        if is_placeholder(matched):
            continue
        FINDINGS.append((label, redact(matched)))

GENERIC_RE = re.compile(
    r'(?i)\b(password|passwd|pwd|api[_-]?key|secret|token|access[_-]?key|private[_-]?key)\b'
    r'\s*[:=]\s*(["\']?)([^\s"\';,)]{4,})\2'
)
for m in GENERIC_RE.finditer(blob):
    field, _, value = m.group(1), m.group(2), m.group(3)
    if is_placeholder(value):
        continue
    if len(value) < MIN_LEN:
        continue
    if shannon_entropy(value) < MIN_ENTROPY:
        continue
    FINDINGS.append(("%s= literal (high-entropy value)" % field, redact(value)))

if FINDINGS:
    print("FOUND")
    for label, preview in FINDINGS:
        print("%s\t%s" % (label, preview))
else:
    print("CLEAN")
PY

RESULT="$(printf '%s' "$INPUT" | python3 "$SCAN_PY" 2>/dev/null || printf 'PARSEFAIL')"

case "$(printf '%s' "$RESULT" | head -1)" in
  CLEAN|PARSEFAIL)
    exit 0
    ;;
  FOUND)
    {
      echo "=== Secret scan BLOCKED ==="
      echo "  Refusing to write '${FILE_PATH:-<unknown file>}' — the content looks like it"
      echo "  contains a live secret:"
      printf '%s\n' "$RESULT" | tail -n +2 | while IFS=$'\t' read -r label preview; do
        echo "    - $label (redacted: $preview)"
      done
      echo "  If this is a genuine placeholder or test fixture, add the exact substring to"
      echo "  SECRET_SCAN_ALLOWLIST in orchestration.config (space-separated, never flagged"
      echo "  again). NEVER commit a real secret — use an environment variable or a secrets"
      echo "  manager instead."
      echo "(hook: scripts/hooks/scan-secrets.sh)"
    } >&2
    exit 2
    ;;
  *)
    # Unexpected python3 output shape — fail closed rather than silently pass.
    echo "ERROR: scan-secrets.sh: unexpected scanner output — refusing (fail-closed)" >&2
    exit 2
    ;;
esac
