#!/usr/bin/env bash
# Parse a corpus of .jac files with the generated parser and report the
# error rate. Usage: scripts/corpus-check.sh <dir> [max_files]
#
# A file "fails" if tree-sitter parse reports any ERROR/MISSING node (non-zero
# exit). Prints overall pass rate and the first failing files for triage.
set -uo pipefail

DIR="${1:?usage: corpus-check.sh <dir> [max_files]}"
MAX="${2:-100000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$(cd "$DIR" && pwd)"
cd "$ROOT"
TS="$ROOT/node_modules/.bin/tree-sitter"
[ -x "$TS" ] || TS="tree-sitter"

mapfile -t FILES < <(find "$DIR" -name '*.jac' -type f | head -n "$MAX")
total=0; pass=0; fail=0
declare -a failed
for f in "${FILES[@]}"; do
  [ -s "$f" ] || continue          # skip empty files
  total=$((total+1))
  if "$TS" parse -q "$f" >/dev/null 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    failed+=("$f")
  fi
done

echo "=================================================="
echo "corpus: $DIR"
echo "parsed: $total   pass: $pass   fail: $fail"
if [ "$total" -gt 0 ]; then
  pct=$(awk "BEGIN{printf \"%.1f\", 100*$pass/$total}")
  echo "pass rate: ${pct}%"
fi
echo "=================================================="
if [ "$fail" -gt 0 ]; then
  echo "first failing files:"
  printf '  %s\n' "${failed[@]:0:25}"
fi
