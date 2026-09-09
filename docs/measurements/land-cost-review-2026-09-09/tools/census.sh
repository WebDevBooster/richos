#!/bin/bash
R=/Users/alex/ab/richos-wt/frank-opus-lc2
cd "$R" || exit 1
lib=0; own=0; libnames=(); ownnames=()
for f in engine/scripts/hooks/*.mutation.sh; do
  if grep -qE '^\s*mutant\s' "$f"; then lib=$((lib+1)); libnames+=("$(basename "$f")");
  else own=$((own+1)); ownnames+=("$(basename "$f")"); fi
done
echo "harnesses using the library's mutant() loop : $lib"
echo "harnesses with their OWN loop               : $own"
echo "--- own-loop harnesses (Sage#2 said there are FOUR) ---"
printf '  %s\n' "${ownnames[@]}"
echo "=== mutant declarations via library mutant() lines ==="
grep -hcE '^\s*mutant\s' engine/scripts/hooks/*.mutation.sh 2>/dev/null | paste -sd+ - | bc
