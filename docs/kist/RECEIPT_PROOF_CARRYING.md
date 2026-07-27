# Proof-carrying patches

A patch can carry machine-checkable CLAIMS about itself. `kist --verify --proofs <file>` evaluates each claim
DETERMINISTICALLY against the actual staged diff and folds the results into the receipt. A required claim that
doesn't hold fails the verdict → the change can't merge. This turns an agent's self-description ("I added a test",
"I introduced no force-unwraps", "I only touched the parser") into an enforceable contract: a lying patch is
caught by the gate, not trusted.

## Proof file format

```json
{
  "diffDigest": "",
  "claims": [
    {"kind": "added-matches",   "value": "func parseFoo", "required": true,  "note": "added the parser"},
    {"kind": "added-absent",    "value": "!\\s*$",         "required": true,  "note": "no trailing force-unwrap"},
    {"kind": "file-touched",    "value": "Tests/ParserTests.swift", "required": true, "note": "added a test"},
    {"kind": "max-added-lines", "value": "200",            "required": true,  "note": ""},
    {"kind": "scope",           "value": "Sources/Parser/;Tests/", "required": true, "note": "stayed in scope"}
  ]
}
```

- `diffDigest`: empty = "check against whatever is staged"; a non-empty digest is strictly enforced (the set names
  a specific change).
- Each claim → one deterministic receipt check `proof:<kind>`. `required` claims gate the verdict; non-required are
  recorded as advisory.

## Claim kinds (deterministic, total)

| kind | passes when |
|---|---|
| `added-matches` | ≥1 added line matches the regex `value` |
| `added-absent` | NO added line matches the regex `value` (e.g. no force-unwrap, no `TODO`, no debug print) |
| `file-touched` | `value` is among the changed files |
| `file-absent` | `value` is NOT among the changed files |
| `max-added-lines` | count(added lines) ≤ `value` |
| `scope` | every changed file starts with one of `value` (`;`-separated prefixes) |

An unknown kind FAILS closed — a policy referencing a claim this kist can't evaluate never appears satisfied.

## Workflow

```sh
git add -A
# the agent (or a harness) writes its claims about this change:
cat > /tmp/proofs.json <<'JSON'
{"diffDigest":"","claims":[{"kind":"file-touched","value":"Tests/ParserTests.swift"}]}
JSON
kist --verify --verify-cmd "swift build && swift test" --proofs /tmp/proofs.json
git add .kist/receipts && git commit -m "feat: parser + test"
```

The claim results are sealed into the receipt (verdict re-derived from checks), so the gate needs only the receipt
— the proof file is a verify-time input. This is the v1 deterministic core (over added lines + changed files);
richer AST/semantic proofs build on the same fold-into-receipt seam. See `RECEIPT_THREAT_MODEL.md`.
