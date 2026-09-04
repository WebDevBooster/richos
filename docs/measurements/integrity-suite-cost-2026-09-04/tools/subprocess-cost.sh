#!/bin/bash
# What does one subprocess of each kind actually cost on this machine?
echo "python3 is: $(command -v python3)"
echo ""

t() { # <label> <count> <command...>
    local label="$1" n="$2"; shift 2
    local s e
    s=$(perl -MTime::HiRes=time -e 'printf "%.4f\n", time')
    local i=0
    while [ "$i" -lt "$n" ]; do "$@" >/dev/null 2>&1; i=$((i+1)); done
    e=$(perl -MTime::HiRes=time -e 'printf "%.4f\n", time')
    perl -e 'printf "%-38s %3d calls %7.2fs  = %6.1f ms each\n", $ARGV[0], $ARGV[1], $ARGV[3]-$ARGV[2], 1000*($ARGV[3]-$ARGV[2])/$ARGV[1]' "$label" "$n" "$s" "$e"
}

t "python3 -c pass"            50 python3 -c pass
t "python3 -c 'import json'"   50 python3 -c 'import json'
t "python3 -c 'import json,sys,os,re'" 50 python3 -c 'import json,sys,os,re'
t "git --version"              50 git --version
t "shasum -a 256 /etc/hosts"   50 shasum -a 256 /etc/hosts
t "grep on /etc/hosts"         50 grep -q localhost /etc/hosts
t "sed on /etc/hosts"          50 sed -n 1p /etc/hosts
t "awk on /etc/hosts"          50 awk 'NR==1' /etc/hosts
t "/bin/bash -c :"             50 /bin/bash -c :
