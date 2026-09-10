"""What this machine IS, and what it is currently holding — read, never assumed.

This tool exists to answer one question the resolver design turns on: which machine-readable
signal should choose the model? Three candidates were on the table — total physical RAM, memory
available right now, and macOS's own memory-pressure level. Two of them are disqualified by what
this script prints, and neither disqualification is guessable from a datasheet:

  * `kern.memorystatus_vm_pressure_level` is sampled repeatedly rather than once, because the
    question is not what it reads but whether it is STABLE and whether NORMAL is the common case
    on a working machine. It is not.
  * available memory is printed alongside a second sample so the churn between two consecutive
    reads is visible. A resolver keyed to a number that moves this much resolves differently at
    09:00 and at 15:00 on one machine, which makes two transcripts from one machine
    incomparable — and the model id is written into every transcript's provenance line.

Run: python3 tools/machine-state.py
"""

import re
import subprocess
import time


def vm_stat_bytes():
    out = subprocess.check_output(["vm_stat"], text=True)
    page_size = None
    vals = {}
    for line in out.splitlines():
        m = re.match(r"Mach Virtual Memory Statistics: \(page size of (\d+) bytes\)", line)
        if m:
            page_size = int(m.group(1))
            continue
        m = re.match(r"(.+?):\s+(\d+)\.", line)
        if m:
            vals[m.group(1).strip()] = int(m.group(2))
    return page_size, {k: v * page_size for k, v in vals.items()}


def sysctl(name):
    return subprocess.check_output(["sysctl", "-n", name], text=True).strip()


print("== IDENTITY ==")
for key in (
    "hw.memsize",
    "hw.ncpu",
    "hw.perflevel0.logicalcpu",
    "hw.perflevel1.logicalcpu",
    "hw.pagesize",
    "machdep.cpu.brand_string",
):
    print("  %-32s %s" % (key, sysctl(key)))

print()
print("== CURRENT COMMITMENT, from vm_stat, in BYTES ==")
page_size, b = vm_stat_bytes()
g = lambda k: b.get(k, 0)
free, active, inactive = g("Pages free"), g("Pages active"), g("Pages inactive")
spec, wired, purge = g("Pages speculative"), g("Pages wired down"), g("Pages purgeable")
comp = g("Pages occupied by compressor")
total = int(sysctl("hw.memsize"))

for k, v in [
    ("free", free),
    ("active", active),
    ("inactive", inactive),
    ("speculative", spec),
    ("wired down", wired),
    ("purgeable", purge),
    ("occupied by compressor", comp),
]:
    print("  %-24s %14s" % (k, format(v, ",d")))

nonreclaim = wired + active + comp
avail = free + inactive + spec + purge
print("  " + "-" * 24)
print("  %-24s %14s   (wired + active + compressor)" % ("non-reclaimable set", format(nonreclaim, ",d")))
print("  %-24s %14s   (free + inactive + speculative + purgeable)" % ("available now", format(avail, ",d")))
print("  %-24s %14s" % ("total (hw.memsize)", format(total, ",d")))
print("  non-reclaimable share of total: %.1f%%" % (100.0 * nonreclaim / total))
print("  available share of total:       %.1f%%" % (100.0 * avail / total))

print()
print("== IS PRESSURE A USABLE INPUT? 6 samples, ~1 s apart ==")
print("   1 = NORMAL, 2 = WARN, 4 = CRITICAL")
for i in range(6):
    level = sysctl("kern.memorystatus_vm_pressure_level")
    _, b2 = vm_stat_bytes()
    a2 = (
        b2.get("Pages free", 0)
        + b2.get("Pages inactive", 0)
        + b2.get("Pages speculative", 0)
        + b2.get("Pages purgeable", 0)
    )
    print("  sample %d  pressure=%s  available=%14s" % (i + 1, level, format(a2, ",d")))
    if i < 5:
        time.sleep(1)
