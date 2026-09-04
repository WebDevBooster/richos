#!/bin/bash
# Extract the ordered (verdict, case-name) list from a suite run log.
# This is the artifact the before/after comparison is made on: a faster suite
# that tests something different is a failure, not a win.
awk '$1 == "PASS" || $1 == "FAIL" { print $1 " " $2 }' "$1"
