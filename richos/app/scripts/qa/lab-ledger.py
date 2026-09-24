#!/usr/bin/env python3
"""Did each message reach the isolated test Mac exactly once, word for word?

    lab-ledger.py --timeline DATA/timeline.json TEXT [TEXT ...]
    lab-ledger.py --timeline DATA/timeline.json --texts-file FILE     one message per line
    lab-ledger.py --timeline DATA/timeline.json --jsonl FILE --field NAME
                                                                      the NAME field of every JSON line

The timeline is the one the isolated lab writes (`node richos/mobile/cli/mobile.mjs lab mac`
keeps it at `<cache>/manual-data/timeline.json`, or `<cache>/mac-timeline.json` after it
stops). For every message it counts the user rows with EXACTLY that text and the reply rows
with exactly `REPLY_PREFIX + text` (the lab's scripted reply is `ack: <message>`; set
`--reply-prefix ''` to count replies with the text alone, or `--no-replies` to skip them).

Exit 0 when every message is there exactly once (and so is its reply); 1 when any is missing,
duplicated or altered, listing which, so a delivery that "looked fine" cannot pass; 2 when the
timeline cannot be read or the lab's owner marker beside it is not the isolated lab's. It
refuses a timeline that is not the isolated lab's, because a real conversation is nothing a
test should read. It prints counts, never the rest of the conversation.
"""
import argparse
import json
import sys
from pathlib import Path

OWNER = "richos-mobile-isolated-v1"


def main(argv):
    p = argparse.ArgumentParser(prog="lab-ledger.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--timeline", required=True)
    p.add_argument("texts", nargs="*")
    p.add_argument("--texts-file")
    p.add_argument("--jsonl")
    p.add_argument("--field")
    p.add_argument("--reply-prefix", default="ack: ")
    p.add_argument("--no-replies", action="store_true")
    a = p.parse_args(argv)

    def refuse(msg):
        print(json.dumps({"ok": False, "error": msg}, indent=2))
        return 2

    path = Path(a.timeline)
    owner = path.parent / "lab-owner"
    if not owner.is_file() or owner.read_text().strip() != OWNER:
        return refuse(f"no isolated-lab owner marker ({OWNER}) beside {path}; this reads only the isolated test Mac's timeline")
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as e:
        return refuse(f"unreadable timeline: {e}")
    items = data.get("items", data) if isinstance(data, dict) else data
    if not isinstance(items, list):
        return refuse("the timeline has no list of items")

    wanted = list(a.texts)
    if a.texts_file:
        wanted += [l for l in Path(a.texts_file).read_text().splitlines() if l]
    if a.jsonl:
        if not a.field:
            return refuse("--jsonl needs --field")
        for line in Path(a.jsonl).read_text().splitlines():
            if line.strip():
                wanted.append(json.loads(line)[a.field])
    if not wanted:
        return refuse("name at least one message to look for")

    users = [r.get("text") for r in items if r.get("kind") == "user_message"]
    replies = [r.get("text") for r in items if r.get("kind") == "rich_message"]
    rows, problems = [], []
    for text in wanted:
        row = {"text": text, "userRows": users.count(text)}
        if not a.no_replies:
            row["replyRows"] = replies.count(a.reply_prefix + text)
        rows.append(row)
        if row["userRows"] != 1 or (not a.no_replies and row["replyRows"] != 1):
            problems.append(row)
    ok = not problems
    print(json.dumps({"ok": ok, "messages": len(wanted), "exactlyOnce": len(wanted) - len(problems),
                      "problems": problems, "timelineUserRows": len(users), "timelineReplyRows": len(replies)}, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
