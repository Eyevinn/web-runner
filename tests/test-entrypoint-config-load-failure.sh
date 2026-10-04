#!/usr/bin/env bash
# tests/test-entrypoint-config-load-failure.sh
#
# Behavioural tests for the CONFIG_SVC load block of scripts/docker-entrypoint.sh.
# The real block is extracted from the entrypoint and run with stub `npx`,
# `timeout`, `sleep` and `node` on PATH.
#
# Expected: timeout, non-zero exit and garbled stdout enter the loading-server
# failed state (exec node ... failed); success and an empty store continue.
#
# Usage: bash tests/test-entrypoint-config-load-failure.sh

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Extract the real config block
start=$(grep -n '^LOADED_CONFIG_EXPORTS=""' "$ENTRYPOINT" | head -1 | cut -d: -f1)
end=$(grep -n '^if \[\[ -z "\$APP_URL" \]\]' "$ENTRYPOINT" | head -1 | cut -d: -f1)
if [ -z "$start" ] || [ -z "$end" ]; then
  echo "FAIL: could not locate config block in $ENTRYPOINT"
  exit 1
fi
sed -n "${start},$((end - 1))p" "$ENTRYPOINT" > "$TMP/block.sh"

cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
[ "$STUB_MODE" = "timeout" ] && { echo "x" >> "$STUB_DIR/npx_calls"; exit 124; }
shift
exec "$@"
STUB
cat > "$TMP/bin/npx" <<'STUB'
#!/usr/bin/env bash
echo "x" >> "$STUB_DIR/npx_calls"
case "$STUB_MODE" in
  ok) echo "export FOO='bar'"; echo "export BAZ='1'" ;;
  empty) ;;
  garbled) echo "something unexpected" ;;
  fail) echo "boom" >&2; exit 1 ;;
  expired) echo "Authorization token expired" >&2; exit 1 ;;
esac
STUB
cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$TMP/bin/node" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/node_args"
STUB
chmod +x "$TMP"/bin/*

# run_block <mode> [token] [config_svc]; sets OUT, NPX_CALLS, NODE_ARGS
run_block() {
  rm -f "$TMP/npx_calls" "$TMP/node_args"
  OUT=$(STUB_MODE="$1" STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" OSC_ACCESS_TOKEN="${2-tok}" CONFIG_SVC="${3-mystore}" \
    bash -c 'LOADING_PID=999999; . "'"$TMP"'/block.sh"; echo "CONTINUED FOO=$FOO"' 2>&1)
  NPX_CALLS=0
  [ -f "$TMP/npx_calls" ] && NPX_CALLS=$(wc -l < "$TMP/npx_calls" | tr -d ' ')
  NODE_ARGS=$(cat "$TMP/node_args" 2>/dev/null)
}

# The stub node returns after recording the exec args; "CONTINUED" is still
# printed by the wrapper then, so failure is detected via NODE_ARGS instead.
FAILED_ARGS="/runner/loading-server.js error-page.html failed"

for mode in timeout fail garbled; do
  run_block "$mode"
  [ "$NODE_ARGS" = "$FAILED_ARGS" ] && pass "$mode -> failed state" || fail "$mode -> failed state (args='$NODE_ARGS')"
  [ "$NPX_CALLS" = "3" ] && pass "$mode -> 3 attempts" || fail "$mode -> expected 3 attempts, got $NPX_CALLS"
  echo "$OUT" | grep -q "\[CONFIG\] ERROR: Failed to load config" && pass "$mode -> ERROR line logged" || fail "$mode -> ERROR line missing"
done

run_block expired
[ "$NODE_ARGS" = "$FAILED_ARGS" ] && pass "expired -> failed state" || fail "expired -> failed state"
[ "$NPX_CALLS" = "1" ] && pass "expired -> no retry" || fail "expired -> expected 1 attempt, got $NPX_CALLS"
echo "$OUT" | grep -q "refresh-app-config" && pass "expired -> refresh-app-config hint kept" || fail "expired -> hint missing"

# Passing paths
run_block ok
if echo "$OUT" | grep -q "CONTINUED FOO=bar" && [ -z "$NODE_ARGS" ]; then
  pass "success -> continues with env vars loaded"
else
  fail "success -> continues (out='$OUT')"
fi

run_block empty
if echo "$OUT" | grep -q "CONTINUED" && [ -z "$NODE_ARGS" ] && echo "$OUT" | grep -q "has no parameters"; then
  pass "empty store -> continues (not a failure)"
else
  fail "empty store -> continues (out='$OUT')"
fi

run_block fail tok ""
if [ "$NPX_CALLS" = "0" ] && [ -z "$NODE_ARGS" ]; then
  pass "no CONFIG_SVC -> block skipped"
else
  fail "no CONFIG_SVC -> block skipped"
fi

run_block fail "" mystore
if [ "$NPX_CALLS" = "0" ] && [ -z "$NODE_ARGS" ]; then
  pass "no OSC_ACCESS_TOKEN -> block skipped (unchanged)"
else
  fail "no OSC_ACCESS_TOKEN -> block skipped"
fi

echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
