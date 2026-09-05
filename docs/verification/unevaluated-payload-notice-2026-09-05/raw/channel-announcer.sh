#!/usr/bin/env bash
# Stands in for a PreToolUse guard that could not evaluate its predicate:
# it announces on BOTH channels and exits 0 with NO permissionDecision.
# The question this answers is whether that changes the verdict.
cat >/dev/null 2>&1
echo "CHANPROBE-STDERR: predicate not evaluated" >&2
printf '%s\n' '{"systemMessage":"CHANPROBE-SYSMSG: predicate not evaluated"}'
exit 0
