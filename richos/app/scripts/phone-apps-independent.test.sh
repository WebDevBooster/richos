#!/usr/bin/env bash
# phone-apps-independent.test.sh — the iPhone app and the Android app each carry their own version,
# and raising one selects none of the other app's suites (CEO ruling §91, 2026-09-26). Reads suite
# declarations and source text only: no build, no simulator, no emulator, no network; seconds.
# Rules and their reasons: phone-apps-independent.test.py. phone-apps-independent.mutation.py then
# breaks each rule in a private copy and requires the line that names it to fail.
# It is not in phone-app-suites.tsv on purpose: it tests which suites run, not either app, and its
# `richos/mobile` input holds both apps, so it is a repository tool under its own rule V2.
# run-tests: no-host-screen: Python and Node over text files only
# run-tests: inputs richos/app/scripts richos/mobile
# run-tests: covers richos/app/scripts/phone-apps-independent.test.py richos/app/scripts/phone-apps-independent.mutation.py richos/app/scripts/phone-app-suites.tsv
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "  NOT RUN  phone-apps-independent: python3 is unavailable"
  exit 2
fi
fails=0
PYTHONDONTWRITEBYTECODE=1 python3 "$here/phone-apps-independent.test.py" || fails=$((fails + 1))
PYTHONDONTWRITEBYTECODE=1 python3 "$here/phone-apps-independent.mutation.py" || fails=$((fails + 1))
if [ "$fails" -eq 0 ]; then
  echo "  PASS  phone-apps-independent: each phone app versions and proves itself apart from the other"
  exit 0
fi
echo "  FAIL  phone-apps-independent"
exit 1
