#!/bin/sh
# THE PUBLIC RECEIPT GAUNTLET — an adversarial corpus the receipt gate must survive. Run it against ANY kist build
# to prove the guard holds. Every scenario is a named attack with an expected verdict (BLOCK or ADMIT); the gauntlet
# exits nonzero if a single invariant regresses. This is the "prove it, don't trust it" artifact for the compliance
# primitive — it encodes every hole found during adversarial review so none can silently come back.
#
# Usage:  scripts/receipt-gauntlet.sh
# Requires: a kist that builds (SwiftPM), git, python3 (for tamper scenarios).
# NOTE: no `set -e` — the gauntlet EXPECTS most guard calls to exit nonzero (that's the attack being blocked).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product kist >/dev/null
BIN="$(swift build --product kist --show-bin-path)/kist"
export KIST_RECEIPT_KEY="gauntlet-org-shared-secret-0123456789"
PASS=0; FAIL=0
T="$(mktemp -d)"
newrepo() { d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && git init -q && git config user.email t@t \
  && git config user.name t && git config core.autocrlf false ) ; echo "$d"; }
# assert <label> <expected 0|1|2> <actual>
assert() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want exit $2, got $3)"; FAIL=$((FAIL+1)); fi; }
# ec <base> <head> <dir>: run the gate and print its exit code (|| catches failure so it isn't swallowed).
ec() { "$BIN" --ci-guard "$1" "$2" --project "$3" >/dev/null 2>&1 && echo 0 || echo $?; }

echo "== HMAC tier =="
d=$(newrepo hmac); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init )
b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && printf '2\n'>>f && git add f && git commit -qm "no receipt" )
assert "unreceipted change is BLOCKED" 1 "$(ec "$b" HEAD "$d")"

d=$(newrepo hmac2); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && printf '2\n'>>f && git add f ); "$BIN" --verify --project "$d" >/dev/null 2>&1
( cd "$d" && git add .kist/receipts && git commit -qm ok )
assert "legit receipted change ADMITS" 0 "$(ec "$b" HEAD "$d")"

echo "== fail-closed range resolution =="
d=$(newrepo range); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init && printf '2\n'>>f && git add f && git commit -qm x )
"$BIN" --ci-guard --project "$d" >/dev/null 2>&1; assert "unresolvable base fails closed (exit 2)" 2 "$?"

echo "== smuggle under the excluded receipts dir =="
d=$(newrepo smug); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && mkdir -p .kist/receipts && printf 'BACKDOOR\n'>.kist/receipts/x.swift && git add .kist/receipts/x.swift && git commit -qm smug )
assert "arbitrary file under .kist/receipts is BLOCKED" 1 "$(ec "$b" HEAD "$d")"

d=$(newrepo wrap); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && printf '2\n'>>f && git add f ); "$BIN" --verify --project "$d" >/dev/null 2>&1
RF=$(ls "$d"/.kist/receipts/*.json | head -1)
python3 - "$RF" >/dev/null 2>&1 <<'PY' || true
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["EVIL"]="AKIAIOSFODNN7EXAMPLE"; json.dump(d,open(p,"w"))
PY
( cd "$d" && git add f .kist/receipts && git commit -qm wrapped )
assert "wrapped receipt (extra key) is BLOCKED" 1 "$(ec "$b" HEAD "$d")"

d=$(newrepo keyid); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && printf '2\n'>>f && git add f ); "$BIN" --verify --project "$d" >/dev/null 2>&1
RF=$(ls "$d"/.kist/receipts/*.json | head -1)
python3 - "$RF" >/dev/null 2>&1 <<'PY' || true
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["keyID"]="PAYLOAD"; json.dump(d,open(p,"w"),separators=(",",":"),sort_keys=True)
PY
( cd "$d" && git add f .kist/receipts && git commit -qm keyidtamper )
assert "keyID tamper is BLOCKED" 1 "$(ec "$b" HEAD "$d")"

echo "== non-blob under receipts =="
d=$(newrepo gitlink); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && git update-index --add --cacheinfo 160000,deadbeefdeadbeefdeadbeefdeadbeefdeadbeef,.kist/receipts/sub && git commit -qm gitlink )
assert "gitlink under .kist/receipts is BLOCKED" 1 "$(ec "$b" HEAD "$d")"

echo "== history coverage =="
d=$(newrepo hist); ( cd "$d" && printf 'base\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && git checkout -qb side && mkdir -p .kist/receipts && printf 'evil\n'>.kist/receipts/e.swift && git add .kist/receipts/e.swift && git commit -qm add \
  && git rm -q .kist/receipts/e.swift && git commit -qm del \
  && git checkout -q "$(git rev-parse --abbrev-ref HEAD@{-1} 2>/dev/null || echo master)" 2>/dev/null || true )
( cd "$d" && git checkout -q - 2>/dev/null || true; git merge -q --no-ff side -m merge 2>/dev/null || true )
assert "add-then-delete-in-side-branch is BLOCKED (full history)" 1 "$(ec "$b" HEAD "$d")"

echo "== issuer-signature tier =="
IHOME="$T/ihome"; mkdir -p "$IHOME"; OLDHOME="$HOME"; export HOME="$IHOME"
RP=$("$BIN" --gen-issuer-key acme 2>&1); APUB=$(echo "$RP" | grep "public key" | grep -o '[A-Za-z0-9+/=]\{40,\}')
"$BIN" --trust-issuer acme "$APUB" >/dev/null 2>&1
d=$(newrepo issuer); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && printf '2\n'>>f && git add f ); "$BIN" --verify --project "$d" >/dev/null 2>&1
( cd "$d" && git add .kist/receipts && git commit -qm "receipt, unsigned" )
assert "issuer pinned: unsigned change is BLOCKED" 1 "$(ec "$b" HEAD "$d")"

d=$(newrepo issuer2); ( cd "$d" && printf '1\n'>f && git add f && git commit -qm init ); b=$(cd "$d" && git rev-parse HEAD)
( cd "$d" && printf '2\n'>>f && git add f ); "$BIN" --verify --project "$d" >/dev/null 2>&1
"$BIN" --sign-receipt latest --issuer-key "$IHOME/.config/kist/issuer-acme.key" --project "$d" >/dev/null 2>&1
( cd "$d" && git add .kist/receipts && git commit -qm "receipt + acme sig" )
assert "issuer pinned: acme-signed change ADMITS" 0 "$(ec "$b" HEAD "$d")"

# revoke acme → its signature is rejected
"$BIN" --revoke-issuer acme >/dev/null 2>&1
assert "revoked issuer's signature is REJECTED" 1 "$(ec "$b" HEAD "$d")"
export HOME="$OLDHOME"

echo "== gauntlet complete: $PASS passed, $FAIL failed =="
rm -rf "$T"
[ "$FAIL" -eq 0 ] || { echo "GAUNTLET FAILED"; exit 1; }
echo "GAUNTLET PASSED — the receipt gate survived every adversarial scenario."
