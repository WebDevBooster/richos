#!/usr/bin/env python3
"""Say a hook's notice once per conversation context, not on every tool call.

A hook's additionalContext stays in the model's context for the rest of that context, so a
notice repeated on every call is paid for again on every later request (richos `def8b8960`:
152 copies of the shell notice in one session; richos-hq docs/research/2026-10-31-app-token-
burn finding 2: 10,323 copies of an app worker's assignment notice). say_once keeps one
private record per kind, session and agent under ${CLAUDE_CONFIG_DIR:-~/.claude}/state/<kind>/
and says the text again only in a new session, after the host compacts that context (its
transcript gains a compaction line past the recorded offset; a subagent's own transcript, as
agent_hold.py maps it) or when the text differs. No session, or any failure, says it as before.
Records untouched for 7 days are removed when a new one is made.
"""
import hashlib
import json
import os
import tempfile
import time

# The host's own line when it compacts a conversation (a quoted copy inside a tool result is escaped).
COMPACTED = b'"subtype":"compact_boundary"'
NOTICE_STATE_DAYS = 7


def _safe(value):
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in value)[:120]


def _notice_state(payload, kind):
    """<config>/state/<kind>/<session>__<agent or lead>.json, or None without a session."""
    sid = payload.get("session_id")
    agent = payload.get("agent_id") or "lead"
    if not isinstance(sid, str) or not sid or not isinstance(agent, str):
        return None
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "state", _safe(kind), _safe(sid) + "__" + _safe(agent) + ".json")


def _transcript(payload):
    """The transcript holding this conversation's context: a subagent's own file, as agent_hold.py finds it."""
    path, sid, agent = payload.get("transcript_path"), payload.get("session_id"), payload.get("agent_id")
    if not isinstance(path, str) or not os.path.isabs(path):
        return None
    if isinstance(agent, str) and agent and isinstance(sid, str) and os.path.basename(path) == sid + ".jsonl":
        path = os.path.join(os.path.dirname(path), sid, "subagents", "agent-" + agent + ".jsonl")
    return path


def _compacted_since(path, offset):
    """True when the host wrote a compaction line in `path` after byte `offset`."""
    with open(path, "rb") as fh:
        fh.seek(max(0, offset - len(COMPACTED) + 1))
        tail = b""
        while True:
            chunk = fh.read(1 << 20)
            if not chunk:
                return False
            if COMPACTED in tail + chunk:
                return True
            tail = chunk[-(len(COMPACTED) - 1):]


def say_once(payload, text, kind):
    """`text` the first time this conversation's context would get it, "" after that.

    Once per session and per subagent; said again after the host compacts that context
    (its transcript gains a compaction line) and whenever the text differs. Without a
    session, or on any failure here, the text is said, as it always was."""
    try:
        path = _notice_state(payload, kind)
        if path is None:
            return text
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            rec = None
        rec = rec if isinstance(rec, dict) else {}
        said = rec.get("said") if isinstance(rec.get("said"), list) else []
        transcript = _transcript(payload)
        size = None
        if transcript:
            try:
                size = os.path.getsize(transcript)
            except OSError:
                pass
        if size is not None and said:
            offset = rec.get("offset")
            if (rec.get("transcript") != transcript or not isinstance(offset, int) or size < offset
                    or _compacted_since(transcript, offset)):
                said = []
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
        out = "" if digest in said else text
        if out:
            said = said + [digest]
        directory = os.path.dirname(path)
        if not rec:
            _prune(directory)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".notice.")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"said": said, "transcript": transcript, "offset": size}, fh)
        os.replace(tmp, path)
        return out
    except Exception:
        return text


def _prune(directory):
    """Records untouched for NOTICE_STATE_DAYS go when a new conversation starts."""
    try:
        cutoff = time.time() - NOTICE_STATE_DAYS * 86400
        for name in os.listdir(directory):
            p = os.path.join(directory, name)
            if os.path.getmtime(p) < cutoff:
                os.unlink(p)
    except OSError:
        pass
