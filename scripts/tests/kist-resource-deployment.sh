#!/usr/bin/env bash
set -euo pipefail
umask 077
REPO_ROOT=$(cd -P -- "$(dirname "$0")/../.." && pwd)
# shellcheck source=lib/deployment-fixture.sh
source "$REPO_ROOT/scripts/tests/lib/deployment-fixture.sh"
BUNDLE="$FIXTURE/bin/AgentCore_AgentCore.bundle"
CODE="$BUNDLE/builtin/code-investigation/SKILL.md"
WEB="$BUNDLE/builtin/web-research/SKILL.md"

# A failed first resource installation must restore absence, including newly created directories.
install_release "1.0.0-legacy" "$FIXTURE/fixture-pass" "2026-09-15 01:00:00" legacy v3
[[ ! -e "$BUNDLE" ]]
BEFORE=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
expect_reject first-resource-install-interrupted /usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_INTERRUPT_AFTER=activation MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite
[[ "$REJECTION_STATUS" = 143 ]]
[[ ! -e "$BUNDLE" && ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$BEFORE" ]]

# SwiftPM copies the whole builtin subtree. An unlisted source payload must not become an
# untracked installed resource, even when the binary itself passes the release smoke checks.
EXTRA_SOURCE="$FIXTURE/project/Sources/AgentCore/Skills/builtin/code-investigation/extra.md"
printf 'unexpected built resource\n' > "$EXTRA_SOURCE"
expect_reject unexpected-built-resource /usr/bin/env KIST_REBUILD_TESTING=1 \
  MYTHOS_REPO="$FIXTURE/project" "$FIXTURE/bin/kist-rebuild" --force --skip-suite
/usr/bin/grep -q 'built resource inventory does not match' "$TMP/reject-unexpected-built-resource.err"
[[ ! -e "$BUNDLE" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$BEFORE" ]]
/bin/rm "$EXTRA_SOURCE"

# Exercise the real fixture build/stage/journal/verify path, then archive the installed resources.
/usr/bin/env KIST_REBUILD_TESTING=1 MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite > "$TMP/resource-promotion-a.out" 2>&1
for skill in code-investigation web-research; do
  /usr/bin/cmp -s "$FIXTURE/project/Sources/AgentCore/Skills/builtin/$skill/SKILL.md" \
    "$BUNDLE/builtin/$skill/SKILL.md"
done
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value rollback_semantics) = \
   exact-v4-with-resources ]]
/usr/bin/grep -q '^artifact-closure-count: 7$' "$FIXTURE/bin/kist-current.manifest"
A_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" > "$TMP/resource-archive-a.json"
/bin/cp "$CODE" "$TMP/code-original"
/bin/cp "$WEB" "$TMP/web-original"

printf 'content drift\n' >> "$CODE"
expect_reject resource-content "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/cp "$TMP/code-original" "$CODE"
/bin/chmod 644 "$CODE"
/bin/mv "$WEB" "$TMP/web-missing"
expect_reject resource-missing "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/mv "$TMP/web-missing" "$WEB"
printf 'unexpected resource\n' > "$BUNDLE/builtin/code-investigation/extra.md"
expect_reject resource-extra "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/rm "$BUNDLE/builtin/code-investigation/extra.md"
/bin/mkdir "$BUNDLE/extra-directory"
expect_reject resource-extra-directory "$FIXTURE/bin/kist-dashboard" --provenance-validate
/bin/rmdir "$BUNDLE/extra-directory"
/bin/mv "$CODE" "$TMP/code-unlinked"
/bin/ln -s "$TMP/code-unlinked" "$CODE"
expect_reject resource-symlink "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/rm "$CODE"
/bin/ln "$TMP/code-unlinked" "$CODE"
expect_reject resource-hardlink "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/rm "$CODE"
/bin/mv "$TMP/code-unlinked" "$CODE"
/bin/mv "$BUNDLE/builtin/code-investigation" "$TMP/code-directory"
/bin/ln -s "$TMP/code-directory" "$BUNDLE/builtin/code-investigation"
expect_reject resource-directory-symlink "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/rm "$BUNDLE/builtin/code-investigation"
/bin/mv "$TMP/code-directory" "$BUNDLE/builtin/code-investigation"
/bin/chmod 664 "$WEB"
expect_reject resource-unsafe-mode "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/chmod 644 "$WEB"
/bin/chmod +a "$(/usr/bin/id -un) allow read" "$WEB"
expect_reject resource-acl "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/chmod -N "$WEB"
/bin/cp "$FIXTURE/bin/kist-current.manifest" "$TMP/resource-manifest-complete"
/usr/bin/sed '/^resource-web-research-sha256:/d' "$TMP/resource-manifest-complete" \
  > "$FIXTURE/bin/kist-current.manifest"
expect_reject resource-partial-binding "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/mv "$TMP/resource-manifest-complete" "$FIXTURE/bin/kist-current.manifest"
/bin/chmod 600 "$FIXTURE/bin/kist-current.manifest"
"$FIXTURE/bin/kist-rebuild" --validate-deployment > /dev/null

# A changed source resource must be built, installed and archived as different bytes.
printf 'second source revision\n' >> "$FIXTURE/project/Sources/AgentCore/Skills/builtin/code-investigation/SKILL.md"
/usr/bin/env KIST_REBUILD_TESTING=1 MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite > "$TMP/resource-promotion-b.out" 2>&1
/usr/bin/cmp -s "$FIXTURE/project/Sources/AgentCore/Skills/builtin/code-investigation/SKILL.md" "$CODE"
if /usr/bin/cmp -s "$TMP/code-original" "$CODE"; then
  printf 'promotion retained stale resource bytes\n' >&2; exit 1
fi
B_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
[[ "$B_ID" != "$A_ID" ]]
PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$A_ID" --out "$TMP/resource-rollback.json")
[[ $(printf '%s' "$PLAN_OUT" | json_value target_rollback_semantics) = exact-v4-with-resources ]]
PLAN_DIGEST=$(printf '%s' "$PLAN_OUT" | json_value plan_digest)
ARCHIVED_CODE="$FIXTURE/.kist/release-registry/releases/release-$A_ID/files/kist-resource-code-investigation.md"
/bin/cp "$ARCHIVED_CODE" "$TMP/archive-code-original"
printf 'archive drift\n' >> "$ARCHIVED_CODE"
expect_reject archived-resource-drift "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$TMP/resource-rollback.json" --confirm "$PLAN_DIGEST"
/bin/cp "$TMP/archive-code-original" "$ARCHIVED_CODE"
/bin/chmod 644 "$ARCHIVED_CODE"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$B_ID" ]]
"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$TMP/resource-rollback.json" \
  --confirm "$PLAN_DIGEST" > "$TMP/resource-rollback.out"
/usr/bin/cmp -s "$TMP/code-original" "$CODE"
/usr/bin/cmp -s "$TMP/web-original" "$WEB"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
if compgen -G "$FIXTURE/bin/.kist-resource-*" > /dev/null \
   || compgen -G "$FIXTURE/bin/.kist-rollback-stage.*" > /dev/null \
   || compgen -G "$FIXTURE/.kist-rebuild-private-tmp/kist-source-snapshot.*" > /dev/null; then
  printf 'resource deployment left staging behind\n' >&2; exit 1
fi
printf 'PASS kist resource deployment: real builds, resource trust, archive, rollback and absence recovery\n'
