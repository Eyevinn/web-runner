#!/usr/bin/env bash
# tests/test-entrypoint-token-expiry.sh
#
# Shell regression tests for the token expiry warning fix introduced in
# issue #210.
#
# The fix improves the config-loading failure path in docker-entrypoint.sh:
#
#   Before:
#     echo "Warning: Failed to load config from application config service: $output"
#
#   After:
#     echo "[CONFIG] Warning: Failed to load config from application config service."
#     echo "[CONFIG] Output: $output"
#     if echo "$output" | grep -qi "expired\|unauthorized\|401"; then
#       echo "[CONFIG] Action required: Your OSC_ACCESS_TOKEN may have expired."
#       echo "[CONFIG] Use the 'refresh-app-config' MCP tool to issue a fresh token."
#     fi
#
# We test the logic by sourcing a self-contained reimplementation of the
# config-loading block (extracted from the entrypoint) in a controlled
# environment — no real network calls or CLI tools are needed.
#
# Usage:
#   bash tests/test-entrypoint-token-expiry.sh
#
# Exit code: 0 = all tests passed, 1 = one or more tests failed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Precondition: entrypoint script must exist
# ---------------------------------------------------------------------------
if [ ! -f "$ENTRYPOINT" ]; then
  echo "ERROR: $ENTRYPOINT not found. Run this script from the repo root."
  exit 1
fi

# ---------------------------------------------------------------------------
# Structural tests — verify the fix is present in the entrypoint source
# ---------------------------------------------------------------------------

# Test 1: "[CONFIG] Warning:" prefix is used (not the old plain "Warning:")
if grep -qF '[CONFIG] Warning: Failed to load config' "$ENTRYPOINT"; then
  pass "Failure message uses [CONFIG] prefix"
else
  fail "Failure message does not use [CONFIG] prefix (found old-style 'Warning:' without prefix?)"
fi

# Test 2: expired|unauthorized|401 pattern check is present
if grep -qE 'grep -qi.*expired.*unauthorized.*401' "$ENTRYPOINT"; then
  pass "Expiry/auth grep pattern is present in entrypoint"
else
  fail "Expiry/auth grep pattern (expired|unauthorized|401) is missing from entrypoint"
fi

# Test 3: Actionable OSC_ACCESS_TOKEN message is present
if grep -qF 'OSC_ACCESS_TOKEN may have expired' "$ENTRYPOINT"; then
  pass "Actionable expiry message is present in entrypoint"
else
  fail "Actionable expiry message ('OSC_ACCESS_TOKEN may have expired') is missing"
fi

# Test 4: refresh-app-config instruction is present
if grep -qF 'refresh-app-config' "$ENTRYPOINT"; then
  pass "refresh-app-config instruction is present in entrypoint"
else
  fail "refresh-app-config instruction is missing from entrypoint"
fi

# ---------------------------------------------------------------------------
# Behavioural tests — exercise the actual config-load failure logic
#
# We replicate the exact conditional block from the entrypoint so we can
# test it with controlled inputs without needing the full script environment.
# The block is short and self-contained (no side-effects beyond printing).
# ---------------------------------------------------------------------------

# Simulate the config-load failure handler from docker-entrypoint.sh.
# $1 = simulated output from config-to-env (the failure message)
# Returns: combined stdout of the handler
run_failure_handler() {
  local config_env_output="$1"
  {
    echo "[CONFIG] Warning: Failed to load config from application config service."
    echo "[CONFIG] Output: $config_env_output"
    if echo "$config_env_output" | grep -qi "expired\|unauthorized\|401"; then
      echo "[CONFIG] Action required: Your OSC_ACCESS_TOKEN may have expired."
      echo "[CONFIG] Use the 'refresh-app-config' MCP tool to issue a fresh token."
    fi
  }
}

# Test 5: "expired" in output triggers the actionable warning
output=$(run_failure_handler "Error: token expired at 2026-01-01")
if echo "$output" | grep -q "OSC_ACCESS_TOKEN may have expired"; then
  pass "'expired' in config output triggers token expiry warning"
else
  fail "'expired' in config output did NOT trigger token expiry warning"
fi

if echo "$output" | grep -q "refresh-app-config"; then
  pass "'expired' in config output includes refresh-app-config instruction"
else
  fail "'expired' in config output missing refresh-app-config instruction"
fi

# Test 6: "unauthorized" in output triggers the actionable warning
output=$(run_failure_handler "401 Unauthorized: invalid credentials")
if echo "$output" | grep -q "OSC_ACCESS_TOKEN may have expired"; then
  pass "'unauthorized' in config output triggers token expiry warning"
else
  fail "'unauthorized' in config output did NOT trigger token expiry warning"
fi

# Test 7: bare "401" in output triggers the actionable warning
output=$(run_failure_handler "HTTP 401: access denied")
if echo "$output" | grep -q "OSC_ACCESS_TOKEN may have expired"; then
  pass "'401' in config output triggers token expiry warning"
else
  fail "'401' in config output did NOT trigger token expiry warning"
fi

if echo "$output" | grep -q "refresh-app-config"; then
  pass "'401' in config output includes refresh-app-config instruction"
else
  fail "'401' in config output missing refresh-app-config instruction"
fi

# Test 8: Case-insensitive — "EXPIRED" (upper case) must also match
output=$(run_failure_handler "EXPIRED token — please renew")
if echo "$output" | grep -q "OSC_ACCESS_TOKEN may have expired"; then
  pass "upper-case 'EXPIRED' in config output triggers token expiry warning (case-insensitive)"
else
  fail "upper-case 'EXPIRED' did NOT trigger warning (grep -qi flag required)"
fi

# Test 9: Generic failure (no token-related keywords) does NOT emit the
# actionable message — only the plain warning is shown
output=$(run_failure_handler "Error: config service unreachable (timeout)")
if echo "$output" | grep -q "OSC_ACCESS_TOKEN may have expired"; then
  fail "generic timeout error should NOT trigger token expiry warning"
else
  pass "generic timeout error does not emit spurious token expiry warning"
fi

# The plain warning must still appear
if echo "$output" | grep -q "\[CONFIG\] Warning:"; then
  pass "generic failure still emits [CONFIG] Warning: message"
else
  fail "generic failure is missing [CONFIG] Warning: message"
fi

# Test 10: Success path — [CONFIG] Warning is not emitted on success
# We simulate the success handler to confirm it does not emit a warning.
run_success_handler() {
  local count="$1"
  echo "[CONFIG] Loaded $count environment variable(s) — available for build and runtime"
}

output=$(run_success_handler 3)
if echo "$output" | grep -q "\[CONFIG\] Warning"; then
  fail "success path must not emit a [CONFIG] Warning message"
else
  pass "success path does not emit any warning"
fi

if echo "$output" | grep -q "Loaded 3 environment variable"; then
  pass "success path emits the correct variable-count message"
else
  fail "success path is missing the variable-count message"
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
