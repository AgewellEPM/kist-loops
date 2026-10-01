#!/usr/bin/env bash
set -euo pipefail
umask 077
REPO_ROOT=$(cd -P -- "$(dirname "$0")/../.." && pwd)
# shellcheck source=lib/deployment-fixture.sh
source "$REPO_ROOT/scripts/tests/lib/deployment-fixture.sh"

install_release "1.0.0-diagnostic" "$FIXTURE/fixture-pass" "2026-09-30 01:00:00" diagnostic
/bin/cp "$FIXTURE/bin/kist-current.manifest" "$TMP/manifest-before"
/bin/cp "$FIXTURE/bin/kist-current" "$TMP/binary-before"

# Make the final evaluator reject operational drift after the candidate is activated.
# The original installer swallowed this reason, leaving only CalledProcessError.
cat > "$TMP/after-activation" <<'SH'
#!/bin/sh
set -eu
/usr/bin/touch "$HOME/.kist/cortex/diagnostic.pyc"
SH
/bin/chmod 700 "$TMP/after-activation"
expect_reject provenance-diagnostic /usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK="$TMP/after-activation" \
  MYTHOS_REPO="$FIXTURE/project" "$FIXTURE/bin/kist-rebuild" --force --skip-suite
/usr/bin/grep -q 'unbound bytecode' "$TMP/reject-provenance-diagnostic.err"
/usr/bin/grep -q 'post-promotion schema-4 deployment validation failed' \
  "$TMP/reject-provenance-diagnostic.err"
/usr/bin/cmp -s "$TMP/manifest-before" "$FIXTURE/bin/kist-current.manifest"
/usr/bin/cmp -s "$TMP/binary-before" "$FIXTURE/bin/kist-current"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]

# Rollback restores release payloads, not independently mutable operational state.
/bin/rm "$FIXTURE/.kist/cortex/diagnostic.pyc"
"$FIXTURE/bin/kist-rebuild" --validate-deployment > /dev/null
printf 'PASS kist deployment diagnostics: evaluator reason preserved and rollback verified\n'
