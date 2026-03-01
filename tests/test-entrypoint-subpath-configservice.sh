#!/usr/bin/env bash
# tests/test-entrypoint-subpath-configservice.sh
#
# Shell regression tests for the subPath + configService .env.osc fix
# introduced to address osaas-deploy-manager issue #200.
#
# The problem:
#   When an app is deployed with SUB_PATH (e.g. "backend" for monorepos) AND
#   CONFIG_SVC, the config service env vars are eval'd into the shell by the
#   root entrypoint. However, workspace-specific start scripts launched in a
#   new shell context (e.g. via npm workspaces or a custom runner) do not
#   inherit those exports.
#
# The fix:
#   After the WORK_DIR is resolved and validated, if SUB_PATH is set and
#   LOADED_CONFIG_EXPORTS is non-empty, the entrypoint writes the variables
#   as KEY=VALUE pairs (without the `export` prefix) to $WORK_DIR/.env.osc.
#   This file can be loaded by dotenv-compatible tools and custom start scripts.
#
# Strategy:
#   1. Structural tests verify the fix is present in the entrypoint source.
#   2. Behavioural tests simulate the relevant entrypoint logic directly so we
#      can exercise it without the full Docker environment.
#
# Usage:
#   bash tests/test-entrypoint-subpath-configservice.sh
#
# Exit code: 0 = all tests pass, 1 = one or more tests failed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Precondition: entrypoint must exist
# ---------------------------------------------------------------------------
if [ ! -f "$ENTRYPOINT" ]; then
  echo "ERROR: $ENTRYPOINT not found. Run this script from the repo root."
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: LOADED_CONFIG_EXPORTS accumulator variable is initialised
#
# The fix introduces a top-level variable LOADED_CONFIG_EXPORTS="" that is
# set to empty before the config-loading block, so it is always defined.
# ---------------------------------------------------------------------------
assert_contains \
  "LOADED_CONFIG_EXPORTS is initialised to empty before config block" \
  'LOADED_CONFIG_EXPORTS=""' \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 2: valid_exports is saved to LOADED_CONFIG_EXPORTS on success
#
# Inside the successful config-load path, the fix adds:
#   LOADED_CONFIG_EXPORTS="$valid_exports"
# ---------------------------------------------------------------------------
assert_contains \
  "valid_exports is saved to LOADED_CONFIG_EXPORTS on success" \
  'LOADED_CONFIG_EXPORTS="$valid_exports"' \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 3: .env.osc write block is present inside the SUB_PATH guard
#
# The fix writes KEY=VALUE pairs to $WORK_DIR/.env.osc.  The sed command
# strips the 'export ' prefix so the file is dotenv-compatible.
# ---------------------------------------------------------------------------
assert_contains \
  ".env.osc write uses sed to strip 'export ' prefix" \
  "sed 's/^export //' > \"\$WORK_DIR/.env.osc\"" \
  "$ENTRYPOINT"

assert_contains \
  ".env.osc write is guarded by non-empty LOADED_CONFIG_EXPORTS check" \
  '[[ -n "$LOADED_CONFIG_EXPORTS" ]]' \
  "$ENTRYPOINT"

assert_contains \
  "confirmation log message references .env.osc" \
  '.env.osc for workspace isolation compatibility' \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 4: .env.osc write block is inside the SUB_PATH if block
#
# Extract the SUB_PATH if block and verify the write logic is inside it.
# ---------------------------------------------------------------------------
subpath_block=$(awk '/if \[\[.*SUB_PATH.*\]\];/{found=1} found{print} /^fi$/{if(found){found=0; exit}}' "$ENTRYPOINT")

if echo "$subpath_block" | grep -qF '.env.osc'; then
  pass ".env.osc write is inside the SUB_PATH if block"
else
  fail ".env.osc write is NOT inside the SUB_PATH if block"
fi

# ---------------------------------------------------------------------------
# Test 5: .env.osc write appears AFTER WORK_DIR validation (the exit 1 guard)
#
# WORK_DIR must be validated before we attempt to write to it.
# The "does not exist" error message appears on the line before the exit 1;
# we locate that message line and use it as the reference point.
# ---------------------------------------------------------------------------
does_not_exist_line=$(grep -n "does not exist" "$ENTRYPOINT" | head -1 | cut -d: -f1)
env_osc_write_line=$(grep -n '.env.osc' "$ENTRYPOINT" | grep 'sed' | head -1 | cut -d: -f1)

if [ -n "$does_not_exist_line" ] && [ -n "$env_osc_write_line" ] && [ "$env_osc_write_line" -gt "$does_not_exist_line" ]; then
  pass ".env.osc write (line $env_osc_write_line) appears after WORK_DIR 'does not exist' guard (line $does_not_exist_line)"
else
  fail ".env.osc write ordering issue (does-not-exist=$does_not_exist_line, write=$env_osc_write_line)"
fi

# ---------------------------------------------------------------------------
# Test 6: Behavioural — .env.osc is written when SUB_PATH + config vars set
#
# Simulate the relevant snippet of the entrypoint in a temp directory.
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d)
WORK_DIR_SIM="$TMP_DIR/backend"
mkdir -p "$WORK_DIR_SIM"

simulate_subpath_envfile() {
  local loaded_exports="$1"
  local work_dir="$2"
  # This mirrors the exact logic added to the entrypoint
  if [[ -n "$loaded_exports" ]]; then
    echo "$loaded_exports" | sed 's/^export //' > "$work_dir/.env.osc"
  fi
}

simulate_subpath_envfile \
  "$(printf 'export DATABASE_URL=postgres://localhost/db\nexport API_KEY=secret123')" \
  "$WORK_DIR_SIM"

if [ -f "$WORK_DIR_SIM/.env.osc" ]; then
  pass ".env.osc file is created when LOADED_CONFIG_EXPORTS and SUB_PATH are set"
else
  fail ".env.osc file was NOT created"
fi

if grep -qF "DATABASE_URL=postgres://localhost/db" "$WORK_DIR_SIM/.env.osc"; then
  pass ".env.osc contains DATABASE_URL without 'export ' prefix"
else
  fail ".env.osc is missing DATABASE_URL or still has 'export ' prefix"
fi

if grep -qF "API_KEY=secret123" "$WORK_DIR_SIM/.env.osc"; then
  pass ".env.osc contains API_KEY without 'export ' prefix"
else
  fail ".env.osc is missing API_KEY or still has 'export ' prefix"
fi

if ! grep -q "^export " "$WORK_DIR_SIM/.env.osc"; then
  pass ".env.osc contains no lines starting with 'export ' (dotenv-compatible)"
else
  fail ".env.osc still has 'export ' prefix — dotenv tools will not parse it correctly"
fi

# ---------------------------------------------------------------------------
# Test 7: Behavioural — .env.osc is NOT written when LOADED_CONFIG_EXPORTS is empty
# ---------------------------------------------------------------------------
WORK_DIR_SIM2="$TMP_DIR/backend2"
mkdir -p "$WORK_DIR_SIM2"
simulate_subpath_envfile "" "$WORK_DIR_SIM2"

if [ ! -f "$WORK_DIR_SIM2/.env.osc" ]; then
  pass ".env.osc is NOT created when LOADED_CONFIG_EXPORTS is empty (no config service)"
else
  fail ".env.osc was created even though LOADED_CONFIG_EXPORTS is empty"
fi

# ---------------------------------------------------------------------------
# Test 8: Behavioural — shell exports remain intact alongside .env.osc
#
# The fix must not remove the eval "$valid_exports" that loads vars into
# the shell environment (needed for the build step).  Verify the eval
# line is still present in the entrypoint.
# ---------------------------------------------------------------------------
assert_contains \
  "eval \"\$valid_exports\" is still present (shell exports not removed)" \
  'eval "$valid_exports"' \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$TMP_DIR"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
