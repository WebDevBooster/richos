#!/bin/bash
# Is `cp -c -R` on this filesystem (a) fast, (b) faithful, (c) genuinely
# independent? A clone that shares state with its template would silently let
# one case contaminate another, which is worse than a slow suite.
set -e
T="$(mktemp -d -t clonecheck-template.XXXXXX)"
mkdir -p "$T/scripts/hooks" "$T/.claude/state"
i=0
while [ $i -lt 60 ]; do
    printf '#!/usr/bin/env bash\necho hook %s\n' "$i" > "$T/scripts/hooks/h$i.sh"
    chmod +x "$T/scripts/hooks/h$i.sh"
    shasum -a 256 "$T/scripts/hooks/h$i.sh" | awk '{print $1}' > "$T/scripts/hooks/h$i.sh.sha256"
    i=$((i+1))
done
printf 'canary\n' > "$T/marker"
BEFORE_SUM="$(cd "$T" && find . -type f | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')"

t_clone() {
    local n="$1" mode="$2" s e
    s=$(perl -MTime::HiRes=time -e 'printf "%.4f\n", time')
    local i=0
    while [ "$i" -lt "$n" ]; do
        d="$(mktemp -d -t clonecheck.XXXXXX)"; rmdir "$d"
        cp $mode "$T" "$d"
        rm -rf "$d"
        i=$((i+1))
    done
    e=$(perl -MTime::HiRes=time -e 'printf "%.4f\n", time')
    perl -e 'printf "%-18s %3d clones %7.3fs = %6.1f ms each\n", $ARGV[0], $ARGV[1], $ARGV[3]-$ARGV[2], 1000*($ARGV[3]-$ARGV[2])/$ARGV[1]' "cp $mode" "$n" "$s" "$e"
}
t_clone 20 "-c -R"
t_clone 20 "-R"

# Independence: mutate one clone, prove the template and a sibling are untouched.
A="$(mktemp -d -t clonecheck-a.XXXXXX)"; rmdir "$A"; cp -c -R "$T" "$A"
B="$(mktemp -d -t clonecheck-b.XXXXXX)"; rmdir "$B"; cp -c -R "$T" "$B"
printf 'TAMPERED\n' > "$A/scripts/hooks/h7.sh"
rm -f "$A/scripts/hooks/h9.sh"
printf 'extra\n' > "$A/new-file"

A_SUM="$(cd "$A" && find . -type f | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')"
T_SUM="$(cd "$T" && find . -type f | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')"
B_SUM="$(cd "$B" && find . -type f | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')"

echo ""
echo "template unchanged after clone was tampered : $([ "$T_SUM" = "$BEFORE_SUM" ] && echo YES || echo 'NO — CLONES ARE NOT INDEPENDENT')"
echo "sibling clone unchanged                     : $([ "$B_SUM" = "$BEFORE_SUM" ] && echo YES || echo 'NO — CLONES ARE NOT INDEPENDENT')"
echo "tampered clone differs                      : $([ "$A_SUM" != "$BEFORE_SUM" ] && echo YES || echo 'NO — the mutation did not take')"
echo "clone is byte-identical to template         : $([ "$B_SUM" = "$BEFORE_SUM" ] && echo YES || echo NO)"
echo "exec bit survives the clone                 : $([ -x "$B/scripts/hooks/h3.sh" ] && echo YES || echo NO)"
echo "empty dir survives the clone                : $([ -d "$B/.claude/state" ] && echo YES || echo NO)"

rm -rf "$T" "$A" "$B"
