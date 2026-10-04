#!/usr/bin/env python3
"""`device perf` prints the §104 cold and warm verdicts itself, and a run with no --out never writes a
`None.evidence` folder into the working directory. No phone is touched."""
import io
import os
import sys
import tempfile
import contextlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import perf  # noqa: E402
import perfcore  # noqa: E402
import watch  # noqa: E402

fails = []


def check(name, cond):
    if not cond:
        fails.append(name)
        print(f"FAIL {name}")


android_ok = {"metrics": {"coldLaunch": {"samplesMs": [900] + [803] * 19}, "warmStandard": perfcore.warm_verdict("android", [150] * 20)}}
lines = perfcore.standard_report("android", android_ok)
check("two verdict lines", len(lines) == 2)
check("cold passes", "cold PASS" in lines[0])
check("warm judged", "warm PASS" in lines[1] or "warm FAIL" in lines[1])

ios_cold_fail = {"metrics": {"coldLaunch": {"samplesMs": [900] * 19}}}
lines = perfcore.standard_report("ios", ios_cold_fail)
check("cold fail", "cold FAIL" in lines[0])
check("warm no verdict with reason", "warm: no verdict" in lines[1] and "metrics.warmStandard" in lines[1])

check("watch uses the same judge", watch.cold_standard("android", android_ok)["verdict"] == "PASS")

# the report is printed by main: a stub run that returns a record
rec = {"platform": "android", **android_ok, "build": {}, "device": {}, "phases": {}, "notMeasured": []}
perf.run_android = lambda args: (rec, 0)
perf.judge = lambda record, bench: False
perf.perfcore.check_record = lambda record: []
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        perf.main(["android", "--adb", "adb", "--serial", "S", "--kind", "physical"])
except SystemExit:
    print(err.getvalue())
    raise
check("main prints §104 cold", "§104 cold PASS" in err.getvalue())
check("main prints §104 warm", "§104 warm" in err.getvalue())

d = perf.default_evidence_dir(None)
check("no-out evidence is scratch", d != "None.evidence" and os.path.isabs(d) and d.startswith(tempfile.gettempdir()))
os.rmdir(d)
check("out-beside evidence kept", perf.default_evidence_dir("/x/r.json") == "/x/r.json.evidence")

_R = "richos/mobile/native-ios/Release/"
check("Release python scripts are tooling", not watch.is_app_code("ios", _R + "check_device_family.py")
      and not watch.is_app_code("ios", _R + "check_sdk_floor.test.py"))
check("Release build inputs stay app code", all(
    watch.is_app_code("ios", _R + n) for n in ("App-Info.plist", "platform.yml", "RichOSNative.entitlements",
                                               "RichOSNative.testcopy.entitlements")))

if fails:
    sys.exit(1)
print("ok")
