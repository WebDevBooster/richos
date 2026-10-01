#!/usr/bin/env python3
"""Append one timestamped line to a step log, for a phone that writes none.

    step-mark.py FILE WORDS...

`phone-android.py` keeps no step log, but `lab-pause.py` follows a text file line by line. This
writes `WORDS... <epoch seconds on this Mac's clock, 3 decimals>` to FILE, so a physical Android
check can mark "PAUSE MAC 1", "HOME 1" and "RELEASE MAC 1" itself, on the same clock as the lab's
intake times. One process, one append, nothing else. Exit 2 with a sentence on a missing argument.
"""
import sys
import time


def main(argv):
    if len(argv) < 3 or argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr if len(argv) >= 2 and argv[1] not in ("-h", "--help") else sys.stdout)
        return 0 if len(argv) >= 2 and argv[1] in ("-h", "--help") else 2
    line = "%s %.3f" % (" ".join(argv[2:]), time.time())
    with open(argv[1], "a", encoding="utf-8") as log:
        log.write(line + "\n")
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
