#!/usr/bin/env bash
# tests/test-entrypoint-package-manager-engines.sh
#
# Shell regression tests for issue #49: honor a deployed app's
# package.json "packageManager" and "engines.node" fields in
# docker-entrypoint.sh, while preserving byte-identical npm-only behavior
# when neither field is present.
#
# Usage:
#   bash tests/test-entrypoint-package-manager-engines.sh
#
# Exit code: 0 = all tests pass, 1 = one or more tests failed.
#
# Strategy: grep/awk-based static assertions against docker-entrypoint.sh,
# matching the style of the other tests/test-entrypoint-*.sh files. A full
# integration test would require running the script inside a container with
# a real cloned repo; these are a fast, dependency-free smoke check.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local description="$1"
  local pattern="$2"
  local file="$3"
  if grep -qF "$pattern" "$file"; then
    pass "$description"
  else
    fail "$description (pattern not found: '$pattern')"
  fi
}

assert_not_contains() {
  local description="$1"
  local pattern="$2"
  local file="$3"
  if ! grep -qF "$pattern" "$file"; then
    pass "$description"
  else
    fail "$description (unexpected pattern found: '$pattern')"
  fi
}

if [ ! -f "$ENTRYPOINT" ]; then
  echo "ERROR: $ENTRYPOINT not found. Run this script from the repo root."
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: engines.node detection is present
# ---------------------------------------------------------------------------
assert_contains \
  "engines.node is read from the deployed app's package.json" \
  "jq -r '.engines.node // empty' \"\$PKG_JSON\"" \
  "$ENTRYPOINT"

assert_contains \
  "a bundled alternate Node major is switched to via PATH" \
  "export PATH=\"/opt/nodejs/\$REQUESTED_MAJOR/bin:\$PATH\"" \
  "$ENTRYPOINT"

assert_contains \
  "unparsable/unsupported engines.node falls back to the image default" \
  "falling back to image default Node \$NODE_IMAGE_DEFAULT_MAJOR" \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 2: packageManager detection is present
# ---------------------------------------------------------------------------
assert_contains \
  "packageManager is read from the deployed app's package.json" \
  "jq -r '.packageManager // empty' \"\$PKG_JSON\"" \
  "$ENTRYPOINT"

assert_contains \
  "pnpm and yarn are recognized as Corepack-managed package managers" \
  "pnpm | yarn)" \
  "$ENTRYPOINT"

assert_contains \
  "pnpm install uses --frozen-lockfile" \
  "pnpm install --frozen-lockfile" \
  "$ENTRYPOINT"

assert_contains \
  "yarn classic (1.x) uses --frozen-lockfile" \
  "yarn install --frozen-lockfile" \
  "$ENTRYPOINT"

assert_contains \
  "yarn berry (>=2) uses --immutable" \
  "yarn install --immutable" \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 3: the lockfile-hash PVC cache key is scoped per package manager
# (prevents restoring an npm-installed node_modules over a pnpm/yarn
# project, or vice versa)
# ---------------------------------------------------------------------------
assert_contains \
  "cache key combines package manager name with the lockfile hash" \
  'CACHE_KEY="$PM_NAME:$LOCKFILE_HASH"' \
  "$ENTRYPOINT"

assert_contains \
  "lockfile name is selected based on detected package manager" \
  'pnpm) LOCKFILE_NAME="pnpm-lock.yaml" ;;' \
  "$ENTRYPOINT"

assert_contains \
  "lockfile name is selected based on detected package manager (yarn)" \
  'yarn) LOCKFILE_NAME="yarn.lock" ;;' \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 4: CMD's leading "npm" token is rewritten to the detected package
# manager at start time, since the image CMD is fixed at build time
# ---------------------------------------------------------------------------
assert_contains \
  "leading npm token in CMD is rewritten to the detected package manager" \
  'RUN_ARGS[0]="$PM_NAME"' \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 5: default path (no packageManager, no engines.node) is unchanged —
# PM_NAME/PM_RUN_BIN/LOCKFILE_NAME default to npm/package-lock.json, and the
# npm install/build commands used for the default case are still present
# verbatim.
# ---------------------------------------------------------------------------
assert_contains \
  "PM_NAME defaults to npm" \
  'PM_NAME="npm"' \
  "$ENTRYPOINT"

assert_contains \
  "PM_RUN_BIN defaults to npm" \
  'PM_RUN_BIN="npm"' \
  "$ENTRYPOINT"

assert_contains \
  "LOCKFILE_NAME defaults to package-lock.json" \
  'LOCKFILE_NAME="package-lock.json"' \
  "$ENTRYPOINT"

assert_contains \
  "default (npm) install command is preserved" \
  "npm install --include=dev" \
  "$ENTRYPOINT"

assert_contains \
  "global husky install always uses npm regardless of detected packageManager" \
  "npm install -g husky 2>/dev/null || true" \
  "$ENTRYPOINT"

# has_script() must gate build/build:app the same way --if-present did
# (skip the script when package.json has no such script; run it otherwise).
assert_contains \
  "build script is only run when present in package.json" \
  "if has_script build; then" \
  "$ENTRYPOINT"

assert_contains \
  "build:app script is only run when the build script succeeded and it is present" \
  "if [ \$BUILD_EXIT -eq 0 ] && has_script build:app; then" \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
