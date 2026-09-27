#!/usr/bin/env python3
"""The orchestrator's pause message: render once, validate before delivery.

No natural-language rewrite is permitted inside a pause control message. This
validates the whole message, including its summary, rather than banning words
such as 'stop' which also occur in 'do not stop'. The only variable fields are a
closed reason enum and a UTC reset time. This module never controls a process.
"""
import argparse
import json
import re
import sys

BODY = "\n".join([
    "PAUSE: preserve this same task, your full context, every workspace and all work in progress.",
    "Pause only. Do not stop, terminate, kill, cancel or restart any running work.",
    "Do not hand off, mark the task complete, remove a workspace or replace the agent.",
    "Hold without starting further work. Resume the same work only when the orchestrator sends RESUME.",
    "If you cannot preserve a running operation while pausing, report that limitation; do not substitute stopping it.",
])
SUMMARY = "PAUSE: preserve work and context"
MARKER = "richos-pause-control: "
# The RESUME that ends a pause. It mentions the pause, so the check below would
# refuse it as a changed pause; it carries its own control line instead and is
# accepted only unchanged. It never carries `pause-until:`, which is what makes
# the registry record a resume (and agent_hold.py continue the held work).
RESUME_BODY = "\n".join([
    "RESUME: continue this same task exactly where it was held, with the same context and workspaces.",
    "Commands that were running when the pause arrived were suspended, and they are running again now. Do not restart them.",
    "A command you started while paused waited without running, and it is running now too.",
    "Elapsed times and timeouts inside that work include the pause, so a timeout it reports may be the pause, not a defect.",
])
RESUME_SUMMARY = "RESUME: continue the held work"
RESUME_MARKER = "richos-resume-control: "
RECIPIENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
CLOCK = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]Z\Z")
# A routing check for declared control messages, not a classifier of user intent.
# The quota watcher always renders a declared control. Rich's manual command does
# the same. Legacy pause-until messages and imperative pause requests are refused
# unless they equal the template, so the incident's handwritten message fails.
# Reserve pause wording and imperative holds in outbound worker messages. This
# deliberately also refuses prose about pausing rather than guessing its intent.
INTENT = re.compile(r"\b(?:pause|pausing|paused)\b|\bhold(?:\s+(?:now|your|all|the|this|until|without|on|position|fire)\b|\s*[:.!?]|\s*$)", re.I)


def render(reason, reset=None):
    if reason not in ("manual", "quota", "weekly-quota"):
        raise ValueError("reason must be manual, quota or weekly-quota")
    if reason == "quota":
        if not isinstance(reset, str) or not CLOCK.fullmatch(reset):
            raise ValueError("quota pause requires its reset time as HH:MMZ")
        until = "the five-hour quota reset at " + reset
    elif reason == "weekly-quota":
        import datetime
        if reset is None:
            until = "the weekly quota reset confirmed by a fresh reading"
        elif not isinstance(reset, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", reset):
            raise ValueError("weekly pause requires its full UTC reset time")
        else:
            datetime.datetime.fromisoformat(reset.replace("Z", "+00:00"))
            until = "the weekly quota reset at " + reset
    else:
        if reset is not None:
            raise ValueError("manual holds have no automatic reset")
        until = "the user's explicit instruction to resume"
    metadata = json.dumps({"version": 1, "reason": reason, "reset": reset}, separators=(",", ":"))
    return BODY + "\n" + MARKER + metadata + "\npause-until: " + until


def render_resume(reason="manual"):
    if reason not in ("manual", "quota", "weekly-quota"):
        raise ValueError("reason must be manual, quota or weekly-quota")
    metadata = json.dumps({"version": 1, "reason": reason}, separators=(",", ":"))
    return RESUME_BODY + "\n" + RESUME_MARKER + metadata


def message_input(to, reason="manual", reset=None, resume=False):
    if not isinstance(to, str) or not RECIPIENT.fullmatch(to):
        raise ValueError("the exact recipient is required")
    if resume:
        if reset is not None:
            raise ValueError("a resume has no reset time")
        return {"to": to, "summary": RESUME_SUMMARY, "message": render_resume(reason)}
    return {"to": to, "summary": SUMMARY, "message": render(reason, reset)}


def validate_resume_text(text):
    if not isinstance(text, str) or len(text) > 8192:
        raise ValueError("invalid resume control message")
    rows = text.splitlines()
    metadata = [row[len(RESUME_MARKER):] for row in rows if row.startswith(RESUME_MARKER)]
    if len(metadata) != 1 or any(row.startswith(MARKER) for row in rows):
        raise ValueError("resume messages must come from pause_protocol.py --resume, unchanged")
    try:
        value = json.loads(metadata[0])
        if set(value) != {"version", "reason"} or value["version"] != 1:
            raise ValueError("invalid resume control fields")
        expected = render_resume(value["reason"])
    except (TypeError, KeyError, json.JSONDecodeError) as error:
        raise ValueError("invalid resume control fields") from error
    if text not in (expected, expected + "\n"):
        raise ValueError("resume instructions were changed; send the generated message unchanged")
    return value


def is_resume(text):
    return isinstance(text, str) and any(row.startswith(RESUME_MARKER) for row in text.splitlines())


def declared(text):
    return isinstance(text, str) and (bool(INTENT.search(text)) or
        bool(re.search(r"(?im)^\s*(?:pause-until|richos-pause-control)\s*:", text)))


def validate_text(text):
    if not isinstance(text, str) or len(text) > 8192:
        raise ValueError("invalid pause control message")
    rows = text.splitlines()
    metadata = [row[len(MARKER):] for row in rows if row.startswith(MARKER)]
    if len(metadata) != 1:
        raise ValueError("pause messages must come from pause_protocol.py, unchanged")
    try:
        value = json.loads(metadata[0])
        if set(value) != {"version", "reason", "reset"} or value["version"] != 1:
            raise ValueError("invalid pause control fields")
        expected = render(value["reason"], value["reset"])
    except (TypeError, KeyError, json.JSONDecodeError) as error:
        raise ValueError("invalid pause control fields") from error
    # Permit the single trailing newline a text file conventionally carries.
    if text not in (expected, expected + "\n"):
        raise ValueError("pause instructions were changed; send the generated message unchanged")
    return value


# Claude Code backfills `content` into the SendMessage input its hooks see, as a
# PREVIEW of `message`: the whole message when it fits in 50 display columns,
# otherwise a prefix and an ellipsis (captured on 2.1.283, 2026-09-27). Never a
# copy of a long message, so demanding equality refused every generated pause.
PREVIEW_COLUMNS = 50
ELLIPSIS = "…"


def is_preview(alias, text):
    """True when alias is text itself, or the harness's truncated preview of it.

    A preview adds no word of its own: everything before its final ellipsis is
    the start of the already-validated message, and it is no longer than the
    harness ever makes one. Anything else is a second instruction.
    """
    if alias == text:
        return True
    if not isinstance(alias, str) or not alias.endswith(ELLIPSIS) or len(alias) > PREVIEW_COLUMNS:
        return False
    head = alias[:-len(ELLIPSIS)]
    return 0 < len(head) < len(text) and text.startswith(head)


def validate_payload(payload):
    if payload.get("tool_name") != "SendMessage":
        return
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        raise ValueError("invalid SendMessage input")
    if "to" in ti and "recipient" in ti and ti["to"] != ti["recipient"]:
        raise ValueError("conflicting SendMessage recipients")
    # Messages reporting to the orchestrator are not instructions from it.
    target = ti.get("to", ti.get("recipient", ""))
    if target in ("main", "team-lead", "lead", "leader", "user") and all(
            ti.get(key, "message") == "message" for key in ("type", "messageType")):
        return
    text = ti.get("message", ti.get("content"))
    summary = ti.get("summary", "")
    if not any(declared(ti.get(key)) for key in ("message", "content", "summary")):
        return
    if not isinstance(target, str) or not RECIPIENT.fullmatch(target):
        raise ValueError("a pause requires the exact recipient")
    if set(ti) - {"to", "recipient", "message", "content", "summary", "type", "messageType"}:
        raise ValueError("pause payload has unexpected fields")
    if is_resume(text):
        validate_resume_text(text)
        if summary not in (None, "", RESUME_SUMMARY):
            raise ValueError("resume summary was changed; use the generated summary unchanged")
    else:
        validate_text(text)
        if summary not in (None, "", SUMMARY):
            raise ValueError("pause summary was changed; use the generated summary unchanged")
    # An alias must not carry a second, contradictory instruction. The harness's
    # own preview of the message is not one.
    if "content" in ti and not is_preview(ti["content"], text):
        raise ValueError("pause content alias must equal the generated message")
    if ti.get("type", "message") != "message" or ti.get("messageType", "message") != "message":
        raise ValueError("a pause is a message, never a shutdown request")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate a hook payload on stdin")
    parser.add_argument("--to")
    parser.add_argument("--reason", choices=("manual", "quota", "weekly-quota"), default="manual")
    parser.add_argument("--reset")
    parser.add_argument("--resume", action="store_true", help="render the RESUME that ends a pause")
    args = parser.parse_args()
    try:
        if args.check:
            raw = sys.stdin.read(262145)
            if len(raw) > 262144:
                raise ValueError("oversized hook payload")
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError("invalid hook payload")
            validate_payload(value)
        else:
            print(json.dumps(message_input(args.to, args.reason, args.reset, resume=args.resume)))
    except (ValueError, TypeError) as error:
        print("REFUSED: " + str(error) + ". Generate the pause with scripts/lib/pause_protocol.py --to <agent>, "
              "and the resume with --resume --to <agent>.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
