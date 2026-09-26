"""Historical quota timelines without wall-clock waits.

Only quota_watch's clock is replaced. Its watch loop, payload parsing, registry,
rule decisions and (R04) subprocess control transport execute unchanged. Real
deadline, polling and registry journeys remain in quota-watch.test.sh.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import sys
import time
from types import SimpleNamespace

import quota_watch as watch


class EndOfReplay(Exception):
    pass


def replay(case, payload, work, engine, fake):
    work.mkdir(parents=True, exist_ok=True)
    historical = case in ("r01", "r02")
    origin = int(time.time())
    renders = [(28, 49), (33, 51), (38, 54), (43, 56),
               (73, 71), (98, 81), (113, 89), (138, 100)]
    reset_min = 220 if case == "r01" else 140
    elapsed = 28 * 60 if historical else 0
    end = 140 * 60 if historical else 900
    reset = origin + (reset_min * 60 if historical else 7200)

    def truth(seconds):
        if not historical:
            return int(91 + 4 * seconds / 600)
        minute = seconds / 60
        for (m0, v0), (m1, v1) in zip(renders, renders[1:]):
            if m0 <= minute <= m1:
                return int(v0 + (v1 - v0) * (minute - m0) / (m1 - m0))
        return renders[-1][1]

    def write(value, at):
        payload.write_text(json.dumps({"rate_limits": {"five_hour": {
            "used_percentage": value, "resets_at": reset}}}))
        os.utime(payload, (origin + at, origin + at))

    def sleep(seconds):
        nonlocal elapsed
        if seconds <= 0:
            raise AssertionError("watch requested a nonpositive sleep")
        target = min(elapsed + seconds, end)
        if historical:
            for minute, value in renders:
                if elapsed < minute * 60 <= target:
                    write(value, minute * 60)
        elapsed = target
        if case == "r04":
            (fake / "used").write_text(str(truth(elapsed)))
        if elapsed >= end:
            raise EndOfReplay

    # Rebinding this module attribute leaves the transport fixture, subprocess
    # timeouts and registry's real process-generation clock untouched.
    watch.time = SimpleNamespace(time=lambda: origin + elapsed, sleep=sleep)
    if case == "r04":
        os.environ["QUOTA_CLAUDE_BIN"] = str(fake / "claude")
    write(49 if historical else 91, elapsed)
    args = SimpleNamespace(threshold=93, threshold_problem="", config="fixture",
                           payload=str(payload), engine_root=str(engine), poll=300,
                           stale=300, until_reset=False, command="quota-watch.sh")
    done, first_alarm, wakes, transcripts = None, None, [], []
    for _ in range(100):
        output = io.StringIO()
        ended = False
        with contextlib.redirect_stdout(output):
            try:
                rc = watch.mode_watch(args)
            except EndOfReplay:
                ended = True
                rc = None
        text = output.getvalue()
        transcripts.append(text)
        if ended:
            break
        threshold = re.search(r"^QUOTA-THRESHOLD (\d+)%", text, re.M)
        if threshold:
            minutes = re.search(r"minutes to reset: (\d+)", text)
            done = ["THRESHOLD", elapsed / 60 if historical else elapsed,
                    int(threshold[1])]
            if historical:
                done.append(int(minutes[1]) if minutes else None)
            break
        wake = re.search(r"^QUOTA-(REFRESH|STALE): the reading is (\d+) s old", text, re.M)
        if not wake or rc != 0:
            raise AssertionError(f"unexpected replay result {rc}: {text}")
        first_alarm = first_alarm if first_alarm is not None else elapsed / 60
        wakes.append([wake[1], int(wake[2])])
        write(truth(elapsed), elapsed)
    else:
        raise AssertionError("replay made no bounded progress")
    text = "\n".join(transcripts)
    (work / "transcript.log").write_text(text)
    if historical:
        return dict(done=done, first_alarm_min=first_alarm, stale_wakes=len(wakes),
                    said_no_pause="less than 20 minutes: no pause" in text, reset_min=reset_min)
    if case == "r03":
        return dict(done=done, wake_ages=wakes)
    return dict(fired_at=done[1] if done else None, value=done[2] if done else None,
                lead_woken=bool(re.search(r"^QUOTA-(STALE|REFRESH|UNKNOWN)", text, re.M)),
                via_get_usage="via get_usage" in text)


if __name__ == "__main__":
    case, payload, work, engine, fake = sys.argv[1:]
    if case not in ("r01", "r02", "r03", "r04"):
        raise SystemExit("unknown replay")
    print(json.dumps(replay(case, Path(payload), Path(work), Path(engine), Path(fake))))
