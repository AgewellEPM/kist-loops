#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_ROOT=$(cd -P -- "$(dirname "$0")/../.." && pwd)
# shellcheck source=lib/deployment-fixture.sh
source "$REPO_ROOT/scripts/tests/lib/deployment-fixture.sh"

# Repository-local runtime telemetry survives promotion and is not part of the reproducible source
# identity.  A tracked script still changes that identity, so the exclusion cannot hide source
# edits or a nested source subtree.
SOURCE_STATE_BEFORE=$("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project")
printf '{"fixture":"still-running"}\n' >> "$FIXTURE/project/.kist/usage.jsonl"
/bin/mkdir -p "$FIXTURE/project/.kist/runs/1785376008-255a334c"
printf '{"event":"still-running"}\n' \
  > "$FIXTURE/project/.kist/runs/1785376008-255a334c/events.jsonl"
SOURCE_STATE_AFTER_RUNTIME=$("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project")
[[ "$SOURCE_STATE_AFTER_RUNTIME" = "$SOURCE_STATE_BEFORE" ]]
[[ -z $(/usr/bin/git -C "$FIXTURE/project" status --porcelain=v1 --untracked-files=all -- . \
  ':(exclude,top).kist/usage.jsonl' \
  ':(exclude,top).kist/runs' ':(exclude,top).kist/runs/**') ]]
RUNTIME_USAGE_HASH=$(/usr/bin/shasum -a 256 "$FIXTURE/project/.kist/usage.jsonl" \
  | /usr/bin/awk '{print $1}')

# The ignored root alternate SwiftPM cache is not source and may contain SwiftPM's convenience
# symlink. The same name nested under Sources remains source.
/bin/mkdir -p "$FIXTURE/project/.build-local/arm64-apple-macosx/debug"
printf 'ignored SwiftPM cache\n' \
  > "$FIXTURE/project/.build-local/arm64-apple-macosx/debug/cache-entry"
/bin/ln -s arm64-apple-macosx/debug "$FIXTURE/project/.build-local/debug"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]
/bin/mkdir -p "$FIXTURE/project/Sources/Kist/.build-local"
printf '// nested alternate build name remains source\n' \
  > "$FIXTURE/project/Sources/Kist/.build-local/Hidden.swift"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") != "$SOURCE_STATE_BEFORE" ]]
/bin/mv "$FIXTURE/project/Sources/Kist/.build-local" "$TMP/nested-build-local-probe"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]

/bin/cp "$FIXTURE/project/scripts/kist-rebuild" "$TMP/tracked-script"
printf '# source mutation\n' >> "$FIXTURE/project/scripts/kist-rebuild"
SOURCE_STATE_AFTER_SOURCE=$("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project")
[[ "$SOURCE_STATE_AFTER_SOURCE" != "$SOURCE_STATE_BEFORE" ]]
[[ $(/usr/bin/git -C "$FIXTURE/project" status --porcelain=v1 --untracked-files=all -- . \
  ':(exclude,top).kist' ':(exclude,top).kist/**') == *"scripts/kist-rebuild"* ]]
/bin/cp "$TMP/tracked-script" "$FIXTURE/project/scripts/kist-rebuild"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]
/bin/mkdir -p "$FIXTURE/project/Sources/Kist/.kist"
printf '// nested source cannot hide behind the runtime directory name\n' \
  > "$FIXTURE/project/Sources/Kist/.kist/Hidden.swift"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") != "$SOURCE_STATE_BEFORE" ]]
/bin/mkdir -p "$FIXTURE/project/.kist/agents"
/bin/mv "$FIXTURE/project/Sources/Kist/.kist" \
  "$FIXTURE/project/.kist/agents/nested-source-probe"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") != "$SOURCE_STATE_BEFORE" ]]
[[ $(/usr/bin/git -C "$FIXTURE/project" status --porcelain=v1 --untracked-files=all -- . \
  ':(exclude,top).kist/usage.jsonl' \
  ':(exclude,top).kist/runs' ':(exclude,top).kist/runs/**') == *".kist/agents"* ]]
/bin/mv "$FIXTURE/project/.kist/agents/nested-source-probe" "$TMP/nested-source-probe"
[[ $("$FIXTURE/bin/kist-rebuild" --print-source-state "$FIXTURE/project") = "$SOURCE_STATE_BEFORE" ]]

# The production snapshot retains child directory modes. These nested read-only directories exercise
# the normal post-build remove_source_snapshot path: successful or rejected promotion must still
# remove its private snapshot without weakening the canonical source tree.
READ_ONLY_SOURCE_PARENT="$FIXTURE/project/Sources/Kist/ReadOnlySnapshot"
/bin/mkdir -m 700 "$READ_ONLY_SOURCE_PARENT"
/bin/mkdir -m 700 "$READ_ONLY_SOURCE_PARENT/Nested"
/bin/chmod 550 "$READ_ONLY_SOURCE_PARENT/Nested"
/bin/chmod 555 "$READ_ONLY_SOURCE_PARENT"
[[ $(/usr/bin/stat -f '%Lp' "$READ_ONLY_SOURCE_PARENT") = 555 ]]
[[ $(/usr/bin/stat -f '%Lp' "$READ_ONLY_SOURCE_PARENT/Nested") = 550 ]]

# Archive two coherent releases. Approval is the exact current release digest, not a short label.
install_release "1.0.0-alpha" "$FIXTURE/fixture-pass" "2026-07-24 10:00:00" alpha v3
/bin/cp "$TMP/closure" "$TMP/alpha-bound-closure"
"$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  > "$TMP/alpha-bound-closure-repeat"
/usr/bin/cmp -s "$TMP/alpha-bound-closure" "$TMP/alpha-bound-closure-repeat"
[[ $(projection_value "$TMP/alpha-bound-closure" dashboard-cortex-count) = 2 ]]
[[ $(projection_value "$TMP/alpha-bound-closure" dashboard-cortex-sha256) =~ ^[a-f0-9]{64}$ ]]
[[ $(projection_value "$TMP/alpha-bound-closure" dashboard-runtime-sha256) =~ ^[a-f0-9]{64}$ ]]

# A deterministic test seam mutates selected cortex only after the full manifest validation. The
# final pre-return inventory must catch that startup-window drift without launching the dashboard.
/bin/cp "$FIXTURE/.kist/cortex/live/app.py" "$TMP/cortex-before-final-revalidation"
FINAL_REVALIDATION_HOOK="$TMP/dashboard-final-revalidation-hook"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "# post-validation cortex drift" >> "$HOME/.kist/cortex/live/app.py"' \
  > "$FINAL_REVALIDATION_HOOK"
/bin/chmod 700 "$FINAL_REVALIDATION_HOOK"
expect_reject post-validation-cortex-drift /usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_DASHBOARD_TEST_AFTER_PROVENANCE_VALIDATION_HOOK="$FINAL_REVALIDATION_HOOK" \
  "$FIXTURE/bin/kist-dashboard" --provenance-validate
/usr/bin/grep -q 'operational state changed after provenance validation' \
  "$TMP/reject-post-validation-cortex-drift.err"
/bin/mv "$TMP/cortex-before-final-revalidation" "$FIXTURE/.kist/cortex/live/app.py"
/bin/chmod 600 "$FIXTURE/.kist/cortex/live/app.py"
"$FIXTURE/bin/kist-dashboard" --provenance-validate

# The operational binding is separate from the fixed five-payload artifact closure. Selected cortex
# additions/content/mode and runtime content alter only their dedicated projection and fail closed.
printf '# selected cortex addition\n' > "$FIXTURE/.kist/cortex/live/added.py"
"$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  > "$TMP/cortex-added-closure"
[[ $(projection_value "$TMP/cortex-added-closure" dashboard-cortex-count) = 3 ]]
[[ $(projection_value "$TMP/cortex-added-closure" dashboard-cortex-sha256) != \
   $(projection_value "$TMP/alpha-bound-closure" dashboard-cortex-sha256) ]]
[[ $(projection_value "$TMP/cortex-added-closure" artifact-closure-sha256) = \
   $(projection_value "$TMP/alpha-bound-closure" artifact-closure-sha256) ]]
expect_reject cortex-selected-addition "$FIXTURE/bin/kist-dashboard" --provenance-validate
/bin/rm -f "$FIXTURE/.kist/cortex/live/added.py"
"$FIXTURE/bin/kist-dashboard" --provenance-validate

/bin/cp "$FIXTURE/.kist/cortex/live/app.py" "$TMP/cortex-app-original"
printf '# selected cortex content drift\n' >> "$FIXTURE/.kist/cortex/live/app.py"
"$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  > "$TMP/cortex-content-closure"
[[ $(projection_value "$TMP/cortex-content-closure" dashboard-cortex-count) = 2 ]]
[[ $(projection_value "$TMP/cortex-content-closure" dashboard-cortex-sha256) != \
   $(projection_value "$TMP/alpha-bound-closure" dashboard-cortex-sha256) ]]
[[ $(projection_value "$TMP/cortex-content-closure" artifact-closure-sha256) = \
   $(projection_value "$TMP/alpha-bound-closure" artifact-closure-sha256) ]]
expect_reject cortex-content-drift "$FIXTURE/bin/kist-dashboard" --provenance-validate
expect_reject rebuild-cortex-content-drift "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/mv "$TMP/cortex-app-original" "$FIXTURE/.kist/cortex/live/app.py"
/bin/chmod 600 "$FIXTURE/.kist/cortex/live/app.py"
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null

/bin/chmod 644 "$FIXTURE/.kist/cortex/live/app.py"
expect_reject cortex-safe-mode-drift "$FIXTURE/bin/kist-dashboard" --provenance-validate
/bin/chmod 600 "$FIXTURE/.kist/cortex/live/app.py"
/bin/cp "$FIXTURE/.kist/scripts/kist_runtime.py" "$TMP/dashboard-runtime-original"
printf '# dashboard runtime content drift\n' >> "$FIXTURE/.kist/scripts/kist_runtime.py"
"$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  > "$TMP/runtime-content-closure"
[[ $(projection_value "$TMP/runtime-content-closure" dashboard-runtime-sha256) != \
   $(projection_value "$TMP/alpha-bound-closure" dashboard-runtime-sha256) ]]
[[ $(projection_value "$TMP/runtime-content-closure" dashboard-cortex-sha256) = \
   $(projection_value "$TMP/alpha-bound-closure" dashboard-cortex-sha256) ]]
[[ $(projection_value "$TMP/runtime-content-closure" artifact-closure-sha256) = \
   $(projection_value "$TMP/alpha-bound-closure" artifact-closure-sha256) ]]
expect_reject dashboard-runtime-content-drift "$FIXTURE/bin/kist-dashboard" --provenance-validate
expect_reject rebuild-runtime-content-drift "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/mv "$TMP/dashboard-runtime-original" "$FIXTURE/.kist/scripts/kist_runtime.py"
/bin/chmod 755 "$FIXTURE/.kist/scripts/kist_runtime.py"
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null

# A previous schema-4 v3 manifest with none of the operational fields remains bootstrap-readable.
# Partial binding is rejected, and the compatibility shape cannot create a fresh archive.
/bin/cp "$FIXTURE/bin/kist-current.manifest" "$TMP/alpha-bound-manifest"
/usr/bin/python3 - "$FIXTURE/bin/kist-current.manifest" partial <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); mode=sys.argv[2]
drop={"dashboard-cortex-count"} if mode=="partial" else {
    "dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"}
lines=[line for line in path.read_text().splitlines(True) if line.split(":",1)[0] not in drop]
path.write_text("".join(lines))
PY
expect_reject partial-v3-operational-binding "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/cp "$TMP/alpha-bound-manifest" "$FIXTURE/bin/kist-current.manifest"
/usr/bin/python3 - "$FIXTURE/bin/kist-current.manifest" legacy <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
drop={"dashboard-runtime-sha256","dashboard-cortex-sha256","dashboard-cortex-count"}
path.write_text("".join(line for line in path.read_text().splitlines(True)
                        if line.split(":",1)[0] not in drop))
PY
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null
UNBOUND_V3_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
UNBOUND_V3_ARCHIVE_ID=$(archive_compat_fixture v3)
[[ "$UNBOUND_V3_ARCHIVE_ID" = "$UNBOUND_V3_ID" ]]
expect_reject unbound-v3-archive "$FIXTURE/bin/kist-rebuild" --release-archive --confirm \
  "$UNBOUND_V3_ID"
/usr/bin/grep -q 'unbound v3 compatibility deployments may be validated but not archived' \
  "$TMP/reject-unbound-v3-archive.err"
/bin/mv "$TMP/alpha-bound-manifest" "$FIXTURE/bin/kist-current.manifest"
/bin/chmod 600 "$FIXTURE/bin/kist-current.manifest"
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null
V3_TRANSITION_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
expect_reject resource-unbound-archive "$FIXTURE/bin/kist-rebuild" --release-archive \
  --confirm "$V3_TRANSITION_ID"
install_release "1.0.0-alpha" "$FIXTURE/fixture-pass" "2026-07-24 10:00:00" alpha
A_STATUS=$("$FIXTURE/bin/kist-rebuild" --release-status)
A_ID=$(printf '%s' "$A_STATUS" | json_value current_release_id)
[[ "$A_ID" =~ ^[a-f0-9]{64}$ ]] || { printf 'invalid alpha release id\n' >&2; exit 1; }

# The short acquisition process exits before this ready marker is published (the coordinating
# child proves fd 9 is closed). The independent open below must still be excluded by the shell's
# descriptor, and must acquire immediately once that shell releases it.
LEASE_TEST_READY="$TMP/parent-lease-ready"
LEASE_TEST_RELEASE="$TMP/parent-lease-release"
/usr/bin/env KIST_REBUILD_TESTING=1 \
  "$FIXTURE/bin/kist-rebuild" --test-hold-deployment-lease \
  "$LEASE_TEST_READY" "$LEASE_TEST_RELEASE" \
  >"$TMP/parent-lease-holder.out" 2>"$TMP/parent-lease-holder.err" &
LEASE_HOLDER_PID=$!
for _ in {1..500}; do
  [[ -s "$LEASE_TEST_READY" ]] && break
  /bin/kill -0 "$LEASE_HOLDER_PID" 2>/dev/null || break
  /bin/sleep .02
done
[[ -s "$LEASE_TEST_READY" ]] || {
  /bin/cat "$TMP/parent-lease-holder.err" >&2
  printf 'parent-owned deployment lease holder did not become ready\n' >&2
  exit 1
}
/usr/bin/python3 -I - "$FIXTURE/bin/.kist-deployment.lock" blocked <<'PY'
import fcntl,os,sys
path,expectation=sys.argv[1:]
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
try:
    try: fcntl.flock(fd,fcntl.LOCK_SH|fcntl.LOCK_NB)
    except BlockingIOError: blocked=True
    else: blocked=False
finally:
    os.close(fd)
raise SystemExit(0 if blocked==(expectation=="blocked") else 1)
PY
/usr/bin/touch "$LEASE_TEST_RELEASE"
wait "$LEASE_HOLDER_PID"
LEASE_HOLDER_PID=""
/usr/bin/python3 -I - "$FIXTURE/bin/.kist-deployment.lock" free <<'PY'
import fcntl,os,sys
path,expectation=sys.argv[1:]
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
try:
    try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: blocked=True
    else: blocked=False
finally:
    os.close(fd)
raise SystemExit(0 if blocked==(expectation=="blocked") else 1)
PY

# The launcher owns its flock descriptor directly. Losing that descriptor after validation is
# fail-closed, and unsafe named lock identities are rejected before any release mutation.
expect_reject dashboard-parent-lease-loss /usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_DASHBOARD_TEST_CLOSE_DEPLOYMENT_LEASE_AFTER_VALIDATION=1 \
  "$FIXTURE/bin/kist-dashboard" --provenance-validate
/usr/bin/grep -q 'deployment lease descriptor is not held by this process' \
  "$TMP/reject-dashboard-parent-lease-loss.err"
LOCK_PATH="$FIXTURE/bin/.kist-deployment.lock"
/bin/mv "$LOCK_PATH" "$TMP/held-deployment-lock"
/bin/ln -s "$TMP/held-deployment-lock" "$LOCK_PATH"
expect_reject symlink-deployment-lock "$FIXTURE/bin/kist-rebuild" --release-status
/bin/rm -f "$LOCK_PATH"
/bin/mv "$TMP/held-deployment-lock" "$LOCK_PATH"
/bin/ln "$LOCK_PATH" "$TMP/deployment-lock-hardlink"
expect_reject hardlinked-deployment-lock "$FIXTURE/bin/kist-dashboard" --provenance-validate
/bin/rm -f "$TMP/deployment-lock-hardlink"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# The dashboard is inside the closure, so its evaluator cannot be allowed to attest only to itself.
# A replacement that replays the previously valid projection must still fail before it is executed.
/bin/cp "$FIXTURE/bin/kist-dashboard" "$TMP/dashboard-before-self-attestation"
"$FIXTURE/bin/kist-dashboard" --provenance-evaluate \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  > "$TMP/replayed-dashboard-closure"
{
  printf '#!/bin/sh\n'
  printf '/bin/cat %s\n' "$TMP/replayed-dashboard-closure"
} > "$FIXTURE/bin/kist-dashboard"
/bin/chmod 755 "$FIXTURE/bin/kist-dashboard"
expect_reject self-attesting-dashboard "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/cp "$TMP/dashboard-before-self-attestation" "$FIXTURE/bin/kist-dashboard"
/bin/chmod 755 "$FIXTURE/bin/kist-dashboard"
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null
/bin/ln "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist-current.alias"
expect_reject hardlinked-installed-payload "$FIXTURE/bin/kist-rebuild" --validate-deployment
/bin/rm -f "$FIXTURE/bin/kist-current.alias"
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null

# The safe launcher binds selection to the installed manifest identity.  A stale identity must
# fail under the exclusive lease before repository selection or compilation begins.
expect_reject stale-safe-selection /usr/bin/env MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --expect-installed-manifest-sha256 \
  0000000000000000000000000000000000000000000000000000000000000000
/usr/bin/grep -q 'installed deployment changed after selection' \
  "$TMP/reject-stale-safe-selection.err"

# CWD is intentionally a repository that passes the old shape heuristic.  With deployed
# provenance unavailable and no explicit MYTHOS_REPO, it must not be selected implicitly.
/bin/mv "$FIXTURE/bin/kist-current.manifest" "$TMP/held-manifest"
set +e
(
  cd "$FIXTURE/project"
  /usr/bin/env -u MYTHOS_REPO "$FIXTURE/bin/kist-rebuild" --force --skip-suite
) >"$TMP/reject-wrong-pwd.out" 2>"$TMP/reject-wrong-pwd.err"
WRONG_PWD_STATUS=$?
set -e
/bin/mv "$TMP/held-manifest" "$FIXTURE/bin/kist-current.manifest"
[[ "$WRONG_PWD_STATUS" -ne 0 ]]
/usr/bin/grep -q 'no canonical Kist repo selected' "$TMP/reject-wrong-pwd.err"

expect_reject wrong-archive "$FIXTURE/bin/kist-rebuild" --release-archive --confirm \
  0000000000000000000000000000000000000000000000000000000000000000
# Matching names in the shared system temp directory are outside this installation's private
# cleanup namespace. Even an unsafe same-host decoy must be ignored and survive exclusive recovery.
GLOBAL_SNAPSHOT_DECOY=$(/usr/bin/mktemp -d /private/tmp/kist-source-snapshot.XXXXXX)
/bin/chmod 777 "$GLOBAL_SNAPSHOT_DECOY"
printf 'foreign namespace decoy\n' > "$GLOBAL_SNAPSHOT_DECOY/source.swift"
A_ARCHIVE=$("$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID")
[[ $(printf '%s' "$A_ARCHIVE" | json_value created) = True ]]
[[ -f "$GLOBAL_SNAPSHOT_DECOY/source.swift" ]]
/bin/rm -rf "$GLOBAL_SNAPSHOT_DECOY"
GLOBAL_SNAPSHOT_DECOY=""
ORPHAN_STAGE="$FIXTURE/bin/.kist-rollback-stage.00000000000000000000000000000000"
printf 'orphan rollback stage\n' > "$ORPHAN_STAGE"
/bin/chmod 600 "$ORPHAN_STAGE"
ARCHIVE_STAGE="$FIXTURE/.kist/release-registry/releases/.release-staging.00000000000000000000000000000000"
/bin/mkdir -m 700 "$ARCHIVE_STAGE"
/bin/mkdir -m 700 "$ARCHIVE_STAGE/files"
printf 'partial archive\n' > "$ARCHIVE_STAGE/files/kist"
/bin/chmod 755 "$ARCHIVE_STAGE/files/kist"
A_REPEAT=$("$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID")
[[ $(printf '%s' "$A_REPEAT" | json_value created) = False ]]
[[ ! -e "$ORPHAN_STAGE" && ! -e "$ARCHIVE_STAGE" ]]

# A SIGKILL before transaction begin can leave only exact mktemp-reserved staging names, and a
# killed build can leave a private source snapshot. The next exclusive recovery removes every
# exact owner-private shape without following a snapshot symlink or widening the deletion boundary.
STALE_PARENT="$FIXTURE/.kist-rebuild-private-tmp"
/bin/mkdir -p "$STALE_PARENT"
/bin/chmod 700 "$STALE_PARENT"
STALE_SNAPSHOT="$STALE_PARENT/kist-source-snapshot.A1b2C3"
/bin/mkdir -m 700 "$STALE_SNAPSHOT"
/bin/mkdir -m 700 "$STALE_SNAPSHOT/nested"
/bin/mkdir -m 700 "$STALE_SNAPSHOT/nested/read-only-child"
printf 'stale source bytes\n' > "$STALE_SNAPSHOT/nested/read-only-child/source.swift"
/bin/chmod 600 "$STALE_SNAPSHOT/nested/read-only-child/source.swift"
/bin/chmod 550 "$STALE_SNAPSHOT/nested/read-only-child"
/bin/chmod 555 "$STALE_SNAPSHOT/nested"
[[ $(/usr/bin/stat -f '%Lp' "$STALE_SNAPSHOT/nested") = 555 ]]
[[ $(/usr/bin/stat -f '%Lp' "$STALE_SNAPSHOT/nested/read-only-child") = 550 ]]
/usr/bin/mkfifo "$STALE_SNAPSHOT/compiler.fifo"
STALE_OUTSIDE="$TMP/stale-snapshot-outside"
printf 'must survive\n' > "$STALE_OUTSIDE"
/bin/ln -s "$STALE_OUTSIDE" "$STALE_SNAPSHOT/outside-link"
printf 'stale suite log\n' > "$STALE_PARENT/kist-rebuild-suite.Z9y8X7"
/bin/chmod 600 "$STALE_PARENT/kist-rebuild-suite.Z9y8X7"
RESERVED_STAGE_PREFIXES=(
  .kist-current.new .kist.wrapper .kist-dashboard .kist-rebuild .kist-safe-rebuild
  .kist-current.manifest .kist-build .kist-current.provenance .kist-status
  .kist-notary-archive .kist-notary-result .kist-current.manifest.final
  .kist-current.provenance.final .kist-current.projection.final
)
for prefix in "${RESERVED_STAGE_PREFIXES[@]}"; do
  printf 'stale stage\n' > "$FIXTURE/bin/${prefix}.A1b2C3"
  /bin/chmod 600 "$FIXTURE/bin/${prefix}.A1b2C3"
done
NEAR_MISS="$FIXTURE/bin/.kist-status.A1b2C"
printf 'not reserved\n' > "$NEAR_MISS"
/bin/chmod 600 "$NEAR_MISS"
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$STALE_SNAPSHOT" && ! -e "$STALE_PARENT/kist-rebuild-suite.Z9y8X7" ]]
[[ -f "$STALE_OUTSIDE" && -f "$NEAR_MISS" ]]
for prefix in "${RESERVED_STAGE_PREFIXES[@]}"; do
  [[ ! -e "$FIXTURE/bin/${prefix}.A1b2C3" ]]
done

# The source/HEAD/branch CAS is repeated while the promoted transaction is still reversible. A
# deterministic post-activation write to an ordinary tracked source must reject and restore the
# exact pre-image rather than committing a manifest for the earlier snapshot.
AFTER_ACTIVATION_HOOK="$TMP/after-activation-churn"
# shellcheck disable=SC2016 # $1 belongs to the generated hook, not this fixture shell.
printf '%s\n' \
  '#!/bin/sh' \
  '/usr/bin/python3 -I -c '"'"'import os; os.close(9)'"'"' 2>/dev/null && exit 82 || :' \
  'printf "%s\n" "after activation" >> "$1/fixture.txt"' \
  > "$AFTER_ACTIVATION_HOOK"
/bin/chmod 700 "$AFTER_ACTIVATION_HOOK"
/bin/cp "$FIXTURE/project/fixture.txt" "$TMP/fixture-before-after-activation"
set +e
/usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK="$AFTER_ACTIVATION_HOOK" \
  MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite \
  >"$TMP/after-activation.out" 2>"$TMP/after-activation.err"
AFTER_ACTIVATION_STATUS=$?
set -e
[[ "$AFTER_ACTIVATION_STATUS" -ne 0 ]]
/usr/bin/grep -q 'changed after activation; rolling back' "$TMP/after-activation.err"
/bin/mv "$TMP/fixture-before-after-activation" "$FIXTURE/project/fixture.txt"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"
[[ -L "$FIXTURE/project/.build/release" ]]
[[ $(/usr/bin/readlink "$FIXTURE/project/.build/release") = arm64-apple-macosx/release ]]
/usr/bin/grep -q '^# SwiftPM release sentinel$' \
  "$FIXTURE/project/.build/arm64-apple-macosx/release/kist"
RETAINED_UNSIGNED_PATHS=("$FIXTURE/project/.build/.kist-provenance"/*)
[[ "${#RETAINED_UNSIGNED_PATHS[@]}" -eq 1 ]]
RETAINED_UNSIGNED_HASH=$(/usr/bin/basename "${RETAINED_UNSIGNED_PATHS[0]}")
[[ "$RETAINED_UNSIGNED_HASH" =~ ^[a-f0-9]{64}$ ]]
[[ -x "${RETAINED_UNSIGNED_PATHS[0]}" ]]
[[ $("/usr/bin/env" KIST_REBUILD_TESTING=1 \
  "$FIXTURE/bin/kist-rebuild" --test-hash-retained-unsigned-artifact \
  "$FIXTURE/project" "$RETAINED_UNSIGNED_HASH") = "$RETAINED_UNSIGNED_HASH" ]]
if compgen -G "$STALE_PARENT/kist-source-snapshot.??????" >/dev/null; then
  printf 'private source snapshot survived rejected after-activation churn\n' >&2
  exit 1
fi

# Semantic evidence validation is part of the still-reversible promotion.  The hook changes the
# canonical pilot bundle and updates its manifest digest, so byte/digest structure remains coherent
# while the bundle's product version no longer matches the manifest. The exclusive validator must
# reject that semantic mismatch and restore the exact installed pre-image.
SEMANTIC_EVIDENCE_HOOK="$TMP/after-activation-semantic-evidence"
printf '%s\n' \
  '#!/usr/bin/python3' \
  'from pathlib import Path' \
  'import hashlib,json,os' \
  'bindir=Path(os.environ["HOME"])/"bin"' \
  'evidence=bindir/"kist-current.provenance.json"' \
  'value=json.loads(evidence.read_text())' \
  'value["product_version"]="0.0.0-semantic-tamper"' \
  'raw=(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()' \
  'evidence.write_bytes(raw)' \
  'manifest=bindir/"kist-current.manifest"' \
  'lines=[]' \
  'for line in manifest.read_text().splitlines(True):' \
  '    if line.startswith("deployment-evidence-sha256: "): line="deployment-evidence-sha256: "+hashlib.sha256(raw).hexdigest()+"\n"' \
  '    lines.append(line)' \
  'manifest.write_text("".join(lines))' \
  > "$SEMANTIC_EVIDENCE_HOOK"
/bin/chmod 700 "$SEMANTIC_EVIDENCE_HOOK"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/semantic-preimage"
set +e
/usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK="$SEMANTIC_EVIDENCE_HOOK" \
  MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite \
  >"$TMP/semantic-evidence.out" 2>"$TMP/semantic-evidence.err"
SEMANTIC_EVIDENCE_STATUS=$?
set -e
[[ "$SEMANTIC_EVIDENCE_STATUS" -ne 0 ]]
/usr/bin/grep -q 'post-promotion evidence, signing, or artifact provenance validation failed' \
  "$TMP/semantic-evidence.err"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/semantic-restored"
/usr/bin/cmp -s "$TMP/semantic-preimage" "$TMP/semantic-restored"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# Losing the parent-owned exclusive descriptor after activation lets an overlapping shared reader
# acquire the file but reject the pending journal. The original shell detects its missing
# descriptor, reacquires exclusive ownership, and rolls the reversible transaction back.
LEASE_LOSS_HOOK="$TMP/after-activation-lease-loss"
# shellcheck disable=SC2016 # HOME belongs to the generated hook.
printf '%s\n' \
  '#!/bin/sh' \
  '/usr/bin/python3 -I -c '"'"'import os; os.close(9)'"'"' 2>/dev/null && exit 82 || :' \
  'if "$HOME/bin/kist-rebuild" --release-status > "$HOME/lease-overlap.out" 2> "$HOME/lease-overlap.err"; then exit 81; fi' \
  'printf "%s\\n" rejected > "$HOME/lease-overlap.marker"' \
  > "$LEASE_LOSS_HOOK"
/bin/chmod 700 "$LEASE_LOSS_HOOK"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/lease-loss-preimage"
set +e
/usr/bin/env KIST_REBUILD_TESTING=1 \
  KIST_REBUILD_TEST_CLOSE_DEPLOYMENT_LEASE_AFTER_ACTIVATION=1 \
  KIST_REBUILD_TEST_AFTER_ACTIVATION_HOOK="$LEASE_LOSS_HOOK" \
  MYTHOS_REPO="$FIXTURE/project" \
  "$FIXTURE/bin/kist-rebuild" --force --skip-suite \
  >"$TMP/lease-loss.out" 2>"$TMP/lease-loss.err"
LEASE_LOSS_STATUS=$?
set -e
[[ "$LEASE_LOSS_STATUS" -ne 0 && -f "$FIXTURE/lease-overlap.marker" ]]
/usr/bin/grep -q 'deployment lease descriptor is not held by this process' "$TMP/lease-loss.err"
/usr/bin/grep -q 'deployment transaction requires exclusive recovery' \
  "$FIXTURE/lease-overlap.err"
/usr/bin/shasum -a 256 \
  "$FIXTURE/bin/kist-current" "$FIXTURE/bin/kist" "$FIXTURE/bin/kist-dashboard" \
  "$FIXTURE/bin/kist-rebuild" "$FIXTURE/bin/kist-safe-rebuild.sh" \
  "$FIXTURE/bin/kist-current.manifest" "$FIXTURE/bin/.kist-build" \
  "$FIXTURE/bin/kist-current.provenance.json" > "$TMP/lease-loss-restored"
/usr/bin/cmp -s "$TMP/lease-loss-preimage" "$TMP/lease-loss-restored"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
if compgen -G "$FIXTURE/bin/.kist-rollback-stage.*" >/dev/null \
   || compgen -G "$STALE_PARENT/kist-source-snapshot.??????" >/dev/null; then
  printf 'lease-loss rollback left transaction staging behind\n' >&2
  exit 1
fi
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta
B_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
[[ "$B_ID" =~ ^[a-f0-9]{64}$ && "$B_ID" != "$A_ID" ]]
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$B_ID" >/dev/null

# Existing eight-file v3 archives from before operational binding remain rollback-compatible. They
# restore the old manifest shape, while returning to a new archive restores all three bound fields.
UNBOUND_V3_PLAN="$TMP/unbound-v3-plan.json"
UNBOUND_V3_PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$UNBOUND_V3_ARCHIVE_ID" \
  --out "$UNBOUND_V3_PLAN")
UNBOUND_V3_PLAN_DIGEST=$(printf '%s' "$UNBOUND_V3_PLAN_OUT" | json_value plan_digest)
[[ $(printf '%s' "$UNBOUND_V3_PLAN_OUT" | json_value target_rollback_semantics) = \
   best-effort-v3-resources-not-archived ]]
"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$UNBOUND_V3_PLAN" \
  --confirm "$UNBOUND_V3_PLAN_DIGEST" >/dev/null
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = \
   "$UNBOUND_V3_ARCHIVE_ID" ]]
/usr/bin/grep -q '^safe-rebuild-sha256:' "$FIXTURE/bin/kist-current.manifest"
if /usr/bin/grep -Eq '^dashboard-(runtime|cortex)' "$FIXTURE/bin/kist-current.manifest"; then
  printf 'old v3 rollback unexpectedly synthesized operational fields\n' >&2
  exit 1
fi
RETURN_BOUND_V3_PLAN="$TMP/return-bound-v3-plan.json"
RETURN_BOUND_V3_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$B_ID" \
  --out "$RETURN_BOUND_V3_PLAN")
RETURN_BOUND_V3_DIGEST=$(printf '%s' "$RETURN_BOUND_V3_OUT" | json_value plan_digest)
"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$RETURN_BOUND_V3_PLAN" \
  --confirm "$RETURN_BOUND_V3_DIGEST" >/dev/null
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$B_ID" ]]
for field in dashboard-runtime-sha256 dashboard-cortex-sha256 dashboard-cortex-count; do
  /usr/bin/grep -q "^${field}:" "$FIXTURE/bin/kist-current.manifest"
done

# V4 archives include both resource payloads with the eight other deployment files. The
# manifest binds operational runtime/cortex state without pretending those bytes are archive data.
B_ARCHIVE_FILES="$FIXTURE/.kist/release-registry/releases/release-$B_ID/files"
[[ $(/usr/bin/find "$B_ARCHIVE_FILES" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ') = 10 ]]
[[ -f "$B_ARCHIVE_FILES/kist-resource-code-investigation.md" \
   && -f "$B_ARCHIVE_FILES/kist-resource-web-research.md" ]]
[[ ! -e "$B_ARCHIVE_FILES/kist_runtime.py" && ! -e "$B_ARCHIVE_FILES/cortex" ]]

# A coherent current deployment may bind a newer operational state, but rollback to a bound archive
# with different runtime/cortex must fail during the dry target check, before transaction activation.
/bin/cp "$FIXTURE/.kist/scripts/kist_runtime.py" "$TMP/runtime-before-bound-rollback"
/bin/cp "$FIXTURE/.kist/cortex/live/app.py" "$TMP/cortex-before-bound-rollback"
printf '# runtime version for newer operational binding\n' >> "$FIXTURE/.kist/scripts/kist_runtime.py"
printf '# cortex version for newer operational binding\n' >> "$FIXTURE/.kist/cortex/live/app.py"
install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta-operational
OPERATIONAL_CURRENT_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
[[ "$OPERATIONAL_CURRENT_ID" != "$B_ID" ]]
BOUND_MISMATCH_PLAN="$TMP/bound-mismatch-plan.json"
BOUND_MISMATCH_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$B_ID" \
  --out "$BOUND_MISMATCH_PLAN")
BOUND_MISMATCH_DIGEST=$(printf '%s' "$BOUND_MISMATCH_OUT" | json_value plan_digest)
expect_reject bound-operational-rollback "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$BOUND_MISMATCH_PLAN" --confirm "$BOUND_MISMATCH_DIGEST"
/usr/bin/grep -q 'rollback target artifact or operational closure does not match' \
  "$TMP/reject-bound-operational-rollback.err"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = \
   "$OPERATIONAL_CURRENT_ID" ]]
/bin/mv "$TMP/runtime-before-bound-rollback" "$FIXTURE/.kist/scripts/kist_runtime.py"
/bin/chmod 755 "$FIXTURE/.kist/scripts/kist_runtime.py"
/bin/mv "$TMP/cortex-before-bound-rollback" "$FIXTURE/.kist/cortex/live/app.py"
/bin/chmod 600 "$FIXTURE/.kist/cortex/live/app.py"
install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$B_ID" ]]

# A coherent target whose binary fails --help must activate, fail the post-activation smoke gate,
# and restore the exact pre-image through the existing durable transaction.
install_release "1.0.0-fail" "$FIXTURE/fixture-fail" "2026-07-24 12:00:00" fail
FAIL_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$FAIL_ID" >/dev/null
install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta
FAIL_PLAN="$TMP/fail-plan.json"
FAIL_PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$FAIL_ID" --out "$FAIL_PLAN")
FAIL_PLAN_DIGEST=$(printf '%s' "$FAIL_PLAN_OUT" | json_value plan_digest)
expect_reject post-activation-smoke "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$FAIL_PLAN" --confirm "$FAIL_PLAN_DIGEST"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$B_ID" ]]
grep -q '^# fixture-release: beta$' "$FIXTURE/bin/kist-safe-rebuild.sh"
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]

# Canonical plan bytes, full plan confirmation, target record bytes, and current-state CAS all bind.
PLAN="$TMP/alpha-plan.json"
PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$A_ID" --out "$PLAN")
PLAN_DIGEST=$(printf '%s' "$PLAN_OUT" | json_value plan_digest)
/bin/cp "$PLAN" "$TMP/tampered-plan.json"
printf ' ' >> "$TMP/tampered-plan.json"
expect_reject tampered-plan "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$TMP/tampered-plan.json" --confirm "$PLAN_DIGEST"
expect_reject wrong-plan-confirm "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$PLAN" --confirm 0000000000000000000000000000000000000000000000000000000000000000
install_release "1.0.0-gamma" "$FIXTURE/fixture-pass" "2026-07-24 13:00:00" gamma
expect_reject stale-current "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$PLAN" --confirm "$PLAN_DIGEST"
install_release "1.0.0-beta" "$FIXTURE/fixture-pass" "2026-07-24 11:00:00" beta

"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$PLAN" --confirm "$PLAN_DIGEST" >"$TMP/apply.out"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '1.0.0-alpha' "$FIXTURE/bin/kist-current.manifest"
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# A process killed after activation leaves a durable journal. Shared readers fail closed; the next
# exclusive release operation recovers alpha before doing any registry work.
INTERRUPT_PLAN="$TMP/interrupt-plan.json"
INTERRUPT_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$B_ID" --out "$INTERRUPT_PLAN")
INTERRUPT_DIGEST=$(printf '%s' "$INTERRUPT_OUT" | json_value plan_digest)
set +e
KIST_REBUILD_TESTING=1 KIST_ROLLBACK_TEST_INTERRUPT_AFTER=activation-sigkill \
  "$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$INTERRUPT_PLAN" \
  --confirm "$INTERRUPT_DIGEST" >"$TMP/interrupt.out" 2>"$TMP/interrupt.err"
INTERRUPT_STATUS=$?
set -e
[[ "$INTERRUPT_STATUS" -ne 0 && -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
expect_reject pending-reader "$FIXTURE/bin/kist-rebuild" --release-status
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# Recovery remains compatible with a pending seven-target journal written by the previous gate.
/usr/bin/python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json,os,shutil,sys
home=Path(sys.argv[1]); bindir=home/"bin"; token="1"*32
targets=["kist-current","kist","kist-dashboard","kist-rebuild",
         "kist-current.manifest",".kist-build","kist-current.provenance.json"]
backup=bindir/f".kist-rebuild-backup.{token}"; backup.mkdir(mode=0o700)
for name in targets:
    source=bindir/name; target=backup/name
    shutil.copyfile(source,target); os.chmod(target,source.stat().st_mode&0o777)
journal={"schema":1,"token":token,"phase":"active","backup":backup.name,"targets":targets,
         "present":{name:True for name in targets},"installed":targets}
(bindir/".kist-rebuild-journal").write_text(
    json.dumps(journal,sort_keys=True,separators=(",",":"))+"\n")
os.chmod(bindir/".kist-rebuild-journal",0o600)
(bindir/"kist").write_text("#!/bin/sh\nexit 97\n"); os.chmod(bindir/"kist",0o755)
PY
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# Recovery accepts only the exact private temp shape that copy_stable can leave in a preparing
# backup. A crash or ENOSPC before the temp rename must not wedge every future deployment.
/usr/bin/python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json,os,sys
home=Path(sys.argv[1]); bindir=home/"bin"; token="2"*32
targets=["kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh",
         "kist-current.manifest",".kist-build","kist-current.provenance.json"]
backup=bindir/f".kist-rebuild-backup.{token}"; backup.mkdir(mode=0o700)
partial=backup/("kist-current.new."+"3"*24)
partial.write_bytes(b"partial backup copy"); partial.chmod(0o600)
journal={"schema":1,"token":token,"phase":"preparing","backup":backup.name,
         "targets":targets,"present":{name:True for name in targets},"installed":[]}
(bindir/".kist-rebuild-journal").write_text(
    json.dumps(journal,sort_keys=True,separators=(",",":"))+"\n")
os.chmod(bindir/".kist-rebuild-journal",0o600)
PY
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ ! -e "$FIXTURE/bin/.kist-rebuild-backup.$(printf '2%.0s' {1..32})" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# Once restored targets and their directory entry are durable, rolled-back is a terminal journal
# phase. Recovery must tolerate a kill after any subset of backup files has already been deleted.
/usr/bin/python3 - "$FIXTURE" <<'PY'
from pathlib import Path
import json,os,shutil,sys
home=Path(sys.argv[1]); bindir=home/"bin"; token="4"*32
targets=["kist-current","kist","kist-dashboard","kist-rebuild","kist-safe-rebuild.sh",
         "kist-current.manifest",".kist-build","kist-current.provenance.json"]
backup=bindir/f".kist-rebuild-backup.{token}"; backup.mkdir(mode=0o700)
shutil.copyfile(bindir/"kist",backup/"kist"); os.chmod(backup/"kist",0o755)
journal={"schema":1,"token":token,"phase":"rolled-back","backup":backup.name,
         "targets":targets,"present":{name:True for name in targets},"installed":targets}
(bindir/".kist-rebuild-journal").write_text(
    json.dumps(journal,sort_keys=True,separators=(",",":"))+"\n")
os.chmod(bindir/".kist-rebuild-journal",0o600)
PY
"$FIXTURE/bin/kist-rebuild" --release-archive --confirm "$A_ID" >/dev/null
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
[[ ! -e "$FIXTURE/bin/.kist-rebuild-backup.$(printf '4%.0s' {1..32})" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]

# A seven-file release record created by the previous release gate remains listable and
# rollback-capable.  Its manifest ignores the installed safe helper; returning to v3 restores the
# helper as the eighth transactional payload.
install_release "0.9.0-legacy" "$FIXTURE/fixture-pass" "2026-07-23 09:00:00" legacy legacy
LEGACY_ID=$(archive_compat_fixture legacy)
[[ "$LEGACY_ID" =~ ^[a-f0-9]{64}$ && "$LEGACY_ID" != "$A_ID" ]]
install_release "1.0.0-alpha" "$FIXTURE/fixture-pass" "2026-07-24 10:00:00" alpha
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
LEGACY_PLAN="$TMP/legacy-plan.json"
LEGACY_PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$LEGACY_ID" --out "$LEGACY_PLAN")
LEGACY_PLAN_DIGEST=$(printf '%s' "$LEGACY_PLAN_OUT" | json_value plan_digest)
[[ $(printf '%s' "$LEGACY_PLAN_OUT" | json_value target_rollback_semantics) = \
   best-effort-legacy-non-self-contained ]]
"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$LEGACY_PLAN" \
  --confirm "$LEGACY_PLAN_DIGEST" >/dev/null
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$LEGACY_ID" ]]
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value rollback_semantics) = \
   best-effort-legacy-non-self-contained ]]
/usr/bin/grep -q '^dashboard-runtime-sha256:' "$FIXTURE/bin/kist-current.manifest"
if /usr/bin/grep -q '^safe-rebuild-sha256:' "$FIXTURE/bin/kist-current.manifest"; then
  printf 'legacy rollback unexpectedly retained a v3 manifest field\n' >&2
  exit 1
fi
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"
RETURN_PLAN="$TMP/return-alpha-plan.json"
RETURN_PLAN_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$A_ID" --out "$RETURN_PLAN")
RETURN_PLAN_DIGEST=$(printf '%s' "$RETURN_PLAN_OUT" | json_value plan_digest)
"$FIXTURE/bin/kist-rebuild" --rollback-apply --plan "$RETURN_PLAN" \
  --confirm "$RETURN_PLAN_DIGEST" >/dev/null
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
/usr/bin/grep -q '^safe-rebuild-sha256:' "$FIXTURE/bin/kist-current.manifest"
/usr/bin/grep -q '^# fixture-release: alpha$' "$FIXTURE/bin/kist-safe-rebuild.sh"

# A legacy record did not archive runtime/cortex. Detect an incompatible operational closure before
# replacing any installed target, and leave the exact current v3 release active.
/bin/cp "$FIXTURE/.kist/scripts/kist_runtime.py" "$TMP/runtime-before-legacy-dry-check"
printf '# incompatible legacy runtime\n' >> "$FIXTURE/.kist/scripts/kist_runtime.py"
install_release "1.0.0-alpha" "$FIXTURE/fixture-pass" "2026-07-24 10:00:00" \
  alpha-operational-new
LEGACY_CHECK_CURRENT_ID=$("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id)
[[ "$LEGACY_CHECK_CURRENT_ID" != "$A_ID" ]]
LEGACY_STALE_PLAN="$TMP/legacy-stale-plan.json"
LEGACY_STALE_OUT=$("$FIXTURE/bin/kist-rebuild" --rollback-plan "$LEGACY_ID" \
  --out "$LEGACY_STALE_PLAN")
LEGACY_STALE_DIGEST=$(printf '%s' "$LEGACY_STALE_OUT" | json_value plan_digest)
expect_reject legacy-operational-closure "$FIXTURE/bin/kist-rebuild" --rollback-apply \
  --plan "$LEGACY_STALE_PLAN" --confirm "$LEGACY_STALE_DIGEST"
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = \
   "$LEGACY_CHECK_CURRENT_ID" ]]
[[ ! -e "$FIXTURE/bin/.kist-rebuild-journal" ]]
/bin/mv "$TMP/runtime-before-legacy-dry-check" "$FIXTURE/.kist/scripts/kist_runtime.py"
/bin/chmod 755 "$FIXTURE/.kist/scripts/kist_runtime.py"
install_release "1.0.0-alpha" "$FIXTURE/fixture-pass" "2026-07-24 10:00:00" alpha
[[ $("$FIXTURE/bin/kist-rebuild" --release-status | json_value current_release_id) = "$A_ID" ]]
[[ $(/usr/bin/shasum -a 256 "$FIXTURE/project/.kist/usage.jsonl" \
  | /usr/bin/awk '{print $1}') = "$RUNTIME_USAGE_HASH" ]]
[[ -f "$FIXTURE/project/.kist/runs/1785376007-155a334c/events.jsonl" ]]
[[ -f "$FIXTURE/project/.kist/runs/1785376008-255a334c/events.jsonl" ]]

LIST=$("$FIXTURE/bin/kist-rebuild" --release-list)
[[ $(printf '%s' "$LIST" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)["releases"]))') = 5 ]]
"$FIXTURE/bin/kist-rebuild" --validate-deployment >/dev/null

printf 'PASS kist deployment protocol: bound v3, old-v3 and legacy rollback, state separation, CAS selection/plans, old-journal recovery, SIGKILL recovery\n'
