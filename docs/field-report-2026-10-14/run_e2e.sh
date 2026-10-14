#!/usr/bin/env bash
# run_e2e.sh — acceptance chain for the ctf improvement prompt.
#
#   1. generate the 13-file adversarial battery (make_fixtures.py)
#   2. aggregate with ctf v4 (path via $CTF or a local clone) -> verify must be 13/13, exit 0
#   3. rebuild the pre-v4 ctf.sh from git history -> diagnose must report BROKEN blocks, exit 1
#   4. (optional) diagnose a field v3 document passed as $1 -> expected: intact (bytes complete)
#
# Usage:  CTF=/path/to/ctf.sh CTF_REPO=/path/to/clone bash run_e2e.sh [field-doc.md]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${TMPDIR:-/tmp}/ctf-e2e.$$"
mkdir -p "$WORK"
fail=0

CTF="${CTF:-}"
CTF_REPO="${CTF_REPO:-$HOME/wiki-work/tools-ctf}"
if [[ -z "$CTF" && -f "$CTF_REPO/ctf.sh" ]]; then CTF="$CTF_REPO/ctf.sh"; fi

echo "== 1. fixtures =="
python3 "$HERE/code/make_fixtures.py" "$WORK/adv" || exit 2

if [[ -n "$CTF" && -f "$CTF" ]]; then
  echo "== 2. ctf v4 aggregate + verify (expect 13 verified / 0 problems) =="
  bash "$CTF" "$WORK/adv" -o "$WORK/v4.md" --metadata --no-timestamp >/dev/null 2>&1
  python3 "$HERE/code/verify_ctf_output.py" "$WORK/v4.md" --sources "$WORK/adv" | tail -1
  python3 "$HERE/code/verify_ctf_output.py" "$WORK/v4.md" --sources "$WORK/adv" >/dev/null 2>&1
  [[ $? -eq 0 ]] && echo "   PASS: v4 round-trip clean" || { echo "   FAIL: v4 round-trip"; fail=1; }

  echo "== 3. pre-v4 (7737cf5^) aggregate + diagnose (expect BROKEN) =="
  if git -C "$CTF_REPO" show '7737cf5^:ctf.sh' > "$WORK/ctf_v3.sh" 2>/dev/null; then
    bash "$WORK/ctf_v3.sh" '*' "$WORK/adv" "$WORK/v3.md" >/dev/null 2>&1
    python3 "$HERE/code/verify_ctf_output.py" "$WORK/v3.md" --diagnose | head -1
    python3 "$HERE/code/verify_ctf_output.py" "$WORK/v3.md" --diagnose >/dev/null 2>&1
    [[ $? -eq 1 ]] && echo "   PASS: pre-v4 corruption detected" || { echo "   FAIL: pre-v4 not flagged"; fail=1; }
  else
    echo "   SKIP: git history for pre-v4 script unavailable (CTF_REPO=$CTF_REPO)"
  fi
else
  echo "== 2/3. SKIP: set CTF=/path/to/ctf.sh (and CTF_REPO for git history) =="
fi

if [[ $# -ge 1 ]]; then
  echo "== 4. field document diagnose: $1 =="
  python3 "$HERE/code/verify_ctf_output.py" "$1" --diagnose | head -2
fi

echo "== done (fail=$fail); workdir kept: $WORK =="
exit "$fail"
