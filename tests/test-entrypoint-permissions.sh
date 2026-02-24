#!/usr/bin/env bash
# tests/test-entrypoint-permissions.sh
#
# Shell regression tests for the /data PVC chown fix introduced in issue #14.
#
# The fix adds two chown commands inside the `if [ -w "/data" ]` block of
# docker-entrypoint.sh so that the "node" user owns /data/next-cache and
# /data/node_modules before the Next.js build starts.  Without this, the
# build process cannot write to the cache directory and crashes with EACCES.
#
# Usage:
#   bash tests/test-entrypoint-permissions.sh
#
# Exit code: 0 = all tests pass, 1 = one or more tests failed.
#
# Strategy:
#   We use grep to assert that the specific chown commands are present in the
#   entrypoint script, which is the authoritative source of truth.  We also
#   verify they appear inside the `if [ -w "/data" ]` block (by checking they
#   follow the mkdir line that only exists inside that block).
#
# Note: A full integration test would require running the script inside a
# Docker container.  These tests act as a fast, dependency-free smoke check
# that the fix was not accidentally reverted.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helper
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

# ---------------------------------------------------------------------------
# Precondition: entrypoint script must exist
# ---------------------------------------------------------------------------
if [ ! -f "$ENTRYPOINT" ]; then
  echo "ERROR: $ENTRYPOINT not found. Run this script from the repo root."
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: /data/next-cache is chowned to node:node
#
# The fix adds:  chown -R node:node /data/next-cache 2>/dev/null || true
# inside the `if [ -w "/data" ]` block.
# ---------------------------------------------------------------------------
assert_contains \
  "chown -R node:node /data/next-cache is present in entrypoint" \
  "chown -R node:node /data/next-cache" \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 2: /data/node_modules is chowned to node:node
#
# The fix adds:  chown -R node:node /data/node_modules 2>/dev/null || true
# ---------------------------------------------------------------------------
assert_contains \
  "chown -R node:node /data/node_modules is present in entrypoint" \
  "chown -R node:node /data/node_modules" \
  "$ENTRYPOINT"

# ---------------------------------------------------------------------------
# Test 3: chown commands are inside the writable-/data guard
#
# Both chown lines must appear AFTER the `if [ -w "/data" ]` line and BEFORE
# the matching `fi` that closes that block.  We extract the block and verify.
# ---------------------------------------------------------------------------
# Extract lines between `if [ -w "/data" ]` and its closing `fi`
writable_block=$(awk '/if \[ -w "\/data" \]/{found=1} found{print} /^fi$/{if(found){found=0}}' "$ENTRYPOINT")

if echo "$writable_block" | grep -qF "chown -R node:node /data/next-cache"; then
  pass "chown /data/next-cache is inside the [ -w /data ] guard"
else
  fail "chown /data/next-cache is NOT inside the [ -w /data ] guard"
fi

if echo "$writable_block" | grep -qF "chown -R node:node /data/node_modules"; then
  pass "chown /data/node_modules is inside the [ -w /data ] guard"
else
  fail "chown /data/node_modules is NOT inside the [ -w /data ] guard"
fi

# ---------------------------------------------------------------------------
# Test 4: chown commands use the 2>/dev/null || true safety pattern
#
# If /data is owned by root the chown may fail when not running as root.
# The fix must not cause the entrypoint to exit on a chown failure.
# ---------------------------------------------------------------------------
if grep -qF "chown -R node:node /data/next-cache 2>/dev/null || true" "$ENTRYPOINT"; then
  pass "chown /data/next-cache uses 2>/dev/null || true (non-fatal)"
else
  fail "chown /data/next-cache is missing 2>/dev/null || true safety pattern"
fi

if grep -qF "chown -R node:node /data/node_modules 2>/dev/null || true" "$ENTRYPOINT"; then
  pass "chown /data/node_modules uses 2>/dev/null || true (non-fatal)"
else
  fail "chown /data/node_modules is missing 2>/dev/null || true safety pattern"
fi

# ---------------------------------------------------------------------------
# Test 5: chown commands appear after mkdir -p (creation before ownership)
#
# mkdir -p /data/node_modules /data/next-cache must come before the chown
# calls so the directories exist before we try to chown them.
# ---------------------------------------------------------------------------
mkdir_line=$(grep -n "mkdir -p /data/node_modules /data/next-cache" "$ENTRYPOINT" | head -1 | cut -d: -f1)
next_cache_chown_line=$(grep -n "chown -R node:node /data/next-cache" "$ENTRYPOINT" | head -1 | cut -d: -f1)

if [ -n "$mkdir_line" ] && [ -n "$next_cache_chown_line" ] && [ "$next_cache_chown_line" -gt "$mkdir_line" ]; then
  pass "chown /data/next-cache appears after mkdir -p (line $mkdir_line < $next_cache_chown_line)"
else
  fail "chown /data/next-cache does not appear after mkdir -p (mkdir=$mkdir_line chown=$next_cache_chown_line)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
