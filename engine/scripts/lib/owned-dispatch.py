#!/usr/bin/env python3
"""Retired owned-outcome hook compatibility entry point.

Live Claude Code sessions may cache this command until restart. The integration
has been removed. This shim deliberately reads no input, changes no state and
starts no processes, allowing those cached hooks to return normally.
"""

if __name__ == "__main__":
    raise SystemExit(0)
