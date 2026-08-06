#!/bin/sh
# Repeatable brutal smoke test for the Verification Receipt git-guard + server-authoritative --ci-guard.
# Builds kist, then attacks the gate: range narrowing, smuggling under the excluded receipts dir, tampered
# receipts, merge coverage, and the legit happy path. Exits nonzero if ANY invariant regresses.
#
# Usage:  scripts/receipt-gate-smoke.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="$(swift build --product kist --show-bin-path)/kist"
swift build --product kist >/dev/null
export KIST_RECEIPT_KEY="${KIST_RECEIPT_KEY:-ci-org-shared-secret-key-1234567890}"
FAIL=0
newrepo() { rm -rf "$1"; mkdir -p "$1"; ( cd "$1" && git init -q && git config user.email t@t && git config user.name t && git config core.autocrlf false ); }
ok()   { echo "  [OK]   $1"; }
bad()  { echo "  [FAIL] $1"; FAIL=1; }

T=$(mktemp -d)

# A: unresolvable base must fail closed (exit 2), never gate a narrowed range.
newrepo "$T/a"
( cd "$T/a" && printf '1\n' > f && git add . && git commit -qm c1 && printf '2\n' >> f && git add f && git commit -qm "c2 no receipt" )
set +e; "$BIN" --ci-guard --project "$T/a" >/dev/null 2>&1; [ $? -eq 2 ] && ok "A: unresolvable base → exit 2" || bad "A: base narrowing not fail-closed"; set -e

# B: arbitrary content under .kist/receipts must be blocked.
newrepo "$T/b"
( cd "$T/b" && printf '1\n' > code.swift && git add . && git commit -qm init )
BASE=$( cd "$T/b" && git rev-parse HEAD )
( cd "$T/b" && mkdir -p .kist/receipts && printf 'let backdoor=1\n' > .kist/receipts/x.swift && git add .kist/receipts/x.swift && git commit -qm smuggle )
set +e; "$BIN" --ci-guard "$BASE" HEAD --project "$T/b" >/dev/null 2>&1; [ $? -eq 1 ] && ok "B: smuggle under receipts blocked" || bad "B: smuggle admitted"; set -e

# C: legit verify→commit→ci-guard admits (digest reproduces).
newrepo "$T/c"
( cd "$T/c" && printf '1\n' > code.swift && git add . && git commit -qm init )
BASE=$( cd "$T/c" && git rev-parse HEAD )
( cd "$T/c" && printf '2\n' >> code.swift && git add code.swift )
"$BIN" --verify --project "$T/c" >/dev/null 2>&1 || true
( cd "$T/c" && git add .kist/receipts && git commit -qm "good+receipt" )
set +e; "$BIN" --ci-guard "$BASE" HEAD --project "$T/c" >/dev/null 2>&1; [ $? -eq 0 ] && ok "C: legit receipted commit admits" || bad "C: legit flow rejected"; set -e

# E: a valid receipt WRAPPED with extra content must be blocked (whole-file authentication).
newrepo "$T/e"
( cd "$T/e" && printf '1\n' > code.swift && git add . && git commit -qm init )
BASE=$( cd "$T/e" && git rev-parse HEAD )
( cd "$T/e" && printf '2\n' >> code.swift && git add code.swift )
"$BIN" --verify --project "$T/e" >/dev/null 2>&1 || true
RF=$( ls "$T/e"/.kist/receipts/*.json | head -1 )
python3 - "$RF" <<'PY' 2>/dev/null || true
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["EVIL"]="payload AKIAIOSFODNN7EXAMPLE"; json.dump(d,open(p,"w"))
PY
( cd "$T/e" && git add code.swift .kist/receipts && git commit -qm "wrapped receipt" )
set +e; "$BIN" --ci-guard "$BASE" HEAD --project "$T/e" >/dev/null 2>&1; [ $? -eq 1 ] && ok "E: wrapped receipt blocked" || bad "E: wrapped receipt admitted"; set -e

# D: merge that brings in unreceipted side content is blocked (first-parent coverage).
newrepo "$T/d"
( cd "$T/d" && printf 'base\n' > f && git add . && git commit -qm init )
BASE=$( cd "$T/d" && git rev-parse HEAD )
( cd "$T/d" && git checkout -qb side && printf 'evil\n' >> f && git add f && git commit -qm "evil side" \
  && git checkout -q "$(git rev-parse --abbrev-ref HEAD@{-1} 2>/dev/null || echo master)" 2>/dev/null || true )
( cd "$T/d" && git checkout -q - 2>/dev/null || true; git merge -q --no-ff side -m merge 2>/dev/null || true )
set +e; "$BIN" --ci-guard "$BASE" HEAD --project "$T/d" >/dev/null 2>&1; [ $? -eq 1 ] && ok "D: unreceipted merge content blocked" || bad "D: merge content slipped"; set -e

# F: keyID smuggle — rewrite only the keyID of a valid receipt (gate5 CRITICAL) → blocked.
newrepo "$T/f"
( cd "$T/f" && printf '1\n' > code.swift && git add . && git commit -qm init )
BASE=$( cd "$T/f" && git rev-parse HEAD )
( cd "$T/f" && printf '2\n' >> code.swift && git add code.swift )
"$BIN" --verify --project "$T/f" >/dev/null 2>&1 || true
RF=$( ls "$T/f"/.kist/receipts/*.json | head -1 )
python3 - "$RF" <<'PY' 2>/dev/null || true
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["keyID"]="PAYLOAD-AKIAIOSFODNN7EXAMPLE"
json.dump(d,open(p,"w"),separators=(",",":"),sort_keys=True)
PY
( cd "$T/f" && git add code.swift .kist/receipts && git commit -qm "keyid smuggle" )
set +e; "$BIN" --ci-guard "$BASE" HEAD --project "$T/f" >/dev/null 2>&1; [ $? -eq 1 ] && ok "F: keyID smuggle blocked" || bad "F: keyID smuggle admitted"; set -e

# G: gitlink (submodule) under .kist/receipts (gate5 HIGH) → blocked.
newrepo "$T/g"
( cd "$T/g" && printf '1\n' > code.swift && git add . && git commit -qm init )
BASE=$( cd "$T/g" && git rev-parse HEAD )
( cd "$T/g" && git update-index --add --cacheinfo 160000,deadbeefdeadbeefdeadbeefdeadbeefdeadbeef,.kist/receipts/sub && git commit -qm gitlink )
set +e; "$BIN" --ci-guard "$BASE" HEAD --project "$T/g" >/dev/null 2>&1; [ $? -eq 1 ] && ok "G: gitlink under receipts blocked" || bad "G: gitlink admitted"; set -e

rm -rf "$T"
[ "$FAIL" -eq 0 ] && echo "ALL RECEIPT-GATE SMOKE CHECKS PASSED" || { echo "RECEIPT-GATE SMOKE FAILURES"; exit 1; }
