#!/usr/bin/env bash
# tests/test-entrypoint-sigterm.sh
#
# Graceful shutdown tests for scripts/docker-entrypoint.sh and
# scripts/loading-server.js (Eyevinn/osaas-deploy-manager#1969).
#
# Every "ns" case runs the script as PID 1 of a fresh PID namespace
# (`unshare -rpf`) and sends `kill -TERM 1` from a sibling. The kernel only
# delivers a signal to PID 1 if PID 1 installed a handler, so a missing trap
# shows up as a timeout (a real red test), not as a pass.
#
# Limitation: `unshare --mount-proc` is not available to an unprivileged user
# on most runners, so inside the namespace /proc is still the host's and ns-local
# pids do not match /proc entries. The ns cases therefore replace only
# app_group_members (the /proc reader) with a shim that translates pids through
# the NSpid field. The real app_group_members is exercised by the "host" cases,
# which run without a namespace and send TERM to the script's pid.
#
# `unshare -rpf` unavailable => FAIL (never skip). SKIP_REAL_PM=1 skips only the
# real package-manager cases (A5); without it a missing binary is a FAIL.
#
# Usage (from the repo root): bash tests/test-entrypoint-sigterm.sh

[ -n "$TRACE" ] && set -x
ENTRYPOINT="scripts/docker-entrypoint.sh"
LOADING="scripts/loading-server.js"
DOCKERFILE="Dockerfile"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! unshare -rpf true 2>/dev/null; then
  echo "FAIL: unshare -rpf unavailable"
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/uc"
REAL_NODE=$(command -v node)
if [ -z "$REAL_NODE" ]; then
  echo "FAIL: node not found"
  exit 1
fi
export REAL_NODE STUB_DIR="$TMP" LEAF="$TMP/leaf.js"

# ---------------------------------------------------------------- fixtures
cat > "$LEAF" <<'JS'
// Stand-in for the user's server: no child processes, SIGTERM handler that
// takes ~2 s to drain.
const fs = require('fs');
const d = process.env.STUB_DIR;
if (process.env.LEAF_MODE === 'exit') {
  setTimeout(() => process.exit(Number(process.env.LEAF_EXIT || 0)), 500);
} else {
  setInterval(() => {}, 1000);
  process.on('SIGTERM', () => {
    fs.appendFileSync(d + '/term_count', 'x\n');
    setTimeout(() => {
      fs.writeFileSync(d + '/marker', 'drained');
      process.exit(Number(process.env.TERM_EXIT || 0));
    }, 2000);
  });
}
fs.writeFileSync(d + '/leaf_started', '1');
JS

# npm / pnpm / yarn stand-in: wrapper process with the leaf as its child. With
# WRAPPER_FWD=1 it forwards TERM like pnpm does; otherwise it ignores it like
# npm/yarn (which exit or do nothing and leave the server behind).
for pm in npm pnpm yarn; do
  cat > "$TMP/bin/$pm" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  run)
    : > "$STUB_DIR/build_started"
    exec sleep "${BUILD_SLEEP:-30}"
    ;;
  install) exit 0 ;;
esac
node "$LEAF" &
L=$!
[ "$WRAPPER_FWD" = 1 ] && trap 'kill -TERM $L 2>/dev/null' TERM
wait $L
rc=$?
while kill -0 $L 2>/dev/null; do wait $L; rc=$?; done
exit $rc
STUB
done
cat > "$TMP/bin/node" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "/runner/loading-server.js" ]; then
  case "$*" in
    *failed*) echo "$*" > "$STUB_DIR/errpage_args"; exit 0 ;;
    *) exec sleep 60 ;;
  esac
fi
exec "$REAL_NODE" "$@"
STUB
cat > "$TMP/bin/setpriv" <<'STUB'
#!/usr/bin/env bash
echo "$*" | cut -d' ' -f1-3 > "$STUB_DIR/setpriv_args"
env | grep -E '^(HOME|SHELL|USER|LOGNAME)=' | sort > "$STUB_DIR/setpriv_env"
shift 3
exec "$@"
STUB
cat > "$TMP/bin/getent" <<'STUB'
#!/usr/bin/env bash
echo "node:x:1000:1000:Linux User,,,:/home/node:/bin/ash"
STUB
cat > "$TMP/bin/chown" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
mkdir -p "$TMP/bin2" && cp "$TMP/bin/setpriv" "$TMP/bin/getent" "$TMP/bin/chown" "$TMP/bin2/"
chmod +x "$TMP"/bin/* "$TMP"/bin2/*

# ------------------------------------------------- assemble the code under test
hstart=$(grep -n '^# BEGIN signal-handling' "$ENTRYPOINT" | head -1 | cut -d: -f1)
hend=$(grep -n '^# END signal-handling' "$ENTRYPOINT" | head -1 | cut -d: -f1)
fstart=$(grep -n '^RUN_ARGS=' "$ENTRYPOINT" | head -1 | cut -d: -f1)
if [ -z "$hstart" ] || [ -z "$hend" ] || [ -z "$fstart" ]; then
  echo "FAIL: could not locate signal-handling helpers / final block in $ENTRYPOINT"
  exit 1
fi
sed -n "${hstart},${hend}p" "$ENTRYPOINT" > "$TMP/helpers.sh"
sed -n "${fstart},\$p" "$ENTRYPOINT" > "$TMP/final_block.sh"

# Test-only replacement for app_group_members inside a PID namespace: read the
# host /proc but print ns-local pids.
cat > "$TMP/shim.sh" <<'SHIM'
app_group_members() {
  local pgid="$1" depth d f stat rest state ppid pgrp last
  local -A map=()
  depth=$(awk '/^NSpid:/{print NF-1}' /proc/self/status)
  for d in /proc/[0-9]*; do
    last=$(awk -v n="$depth" '/^NSpid:/{ if (NF-1==n) print $NF }' "$d/status" 2>/dev/null)
    [ -n "$last" ] && map["${d#/proc/}"]="$last"
  done
  for f in /proc/[0-9]*/stat; do
    d="${f#/proc/}"; d="${d%/stat}"
    [ -n "${map[$d]}" ] || continue
    stat=$(cat "$f" 2>/dev/null) || continue
    rest="${stat##*) }"
    read -r state ppid pgrp _ <<< "$rest"
    [ "${map[$pgrp]}" = "$pgid" ] || continue
    [ "$state" = "Z" ] && continue
    echo "${map[$d]} ${map[$ppid]:-0}"
  done
}
SHIM

{ echo '#!/bin/bash'; cat "$TMP/helpers.sh"; echo 'trap on_term TERM INT'; echo 'PM_NAME="${PM_NAME:-npm}"'; cat "$TMP/final_block.sh"; } > "$TMP/final_host.sh"
{ echo '#!/bin/bash'; cat "$TMP/helpers.sh" "$TMP/shim.sh"; echo 'trap on_term TERM INT'; echo 'PM_NAME="${PM_NAME:-npm}"'; cat "$TMP/final_block.sh"; } > "$TMP/final_ns.sh"

# Whole entrypoint with its paths pointed at the sandbox, for the build-phase case.
sed -e "s#/usercontent#$TMP/uc#g" "$ENTRYPOINT" > "$TMP/entrypoint_sandbox.sh"
echo '{"scripts":{"build":"x"}}' > "$TMP/uc/package.json"

# -------------------------------------------------------------------- runner
# run_final ns|host <cmd...>; env knobs: SEND_TERM, LEAF_MODE, LEAF_EXIT,
# TERM_EXIT, WRAPPER_FWD, PM_NAME, PACKAGE_MANAGER_FIELD. Sets RC and ELAPSED.
run_final() {
  local mode="$1"
  shift
  rm -f "$TMP"/{term_count,marker,leaf_started,errpage_args,setpriv_args,setpriv_env,build_started}
  export PATH="$TMP/bin:$ORIG_PATH"
  local start
  start=$(date +%s.%N)
  if [ "$mode" = ns ]; then
    timeout 25 unshare -rpf bash -c '(if [ "$SEND_TERM" = 1 ]; then while [ ! -f "$STUB_DIR/${WAIT_FILE:-leaf_started}" ]; do sleep 0.1; done; sleep 0.3; kill -TERM 1; fi) & exec bash "$0" "$@"' "$TMP/final_ns.sh" "$@" > "$TMP/out" 2>&1
    RC=$?
  else
    bash "$TMP/final_host.sh" "$@" > "$TMP/out" 2>&1 &
    local pid=$!
    if [ "$SEND_TERM" = 1 ]; then
      (while [ ! -f "$STUB_DIR/leaf_started" ]; do sleep 0.1; done; sleep 0.3; kill -TERM "$pid") &
    fi
    wait "$pid"
    RC=$?
  fi
  ELAPSED=$(awk -v a="$start" -v b="$(date +%s.%N)" "BEGIN{printf \"%.1f\", b-a}")
  export PATH="$ORIG_PATH"
}
ORIG_PATH="$PATH"
terms() { [ -f "$TMP/term_count" ] && wc -l < "$TMP/term_count" | tr -d ' ' || echo 0; }
under() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }

# check_graceful <label> : app drained, handler once, no error page, exit 0
check_graceful() {
  local label="$1" ok=1
  [ -f "$TMP/marker" ] || { ok=0; echo "  no drain marker (rc=$RC)"; }
  [ "$(terms)" = "1" ] || { ok=0; echo "  handler ran $(terms) time(s), expected 1"; }
  [ ! -f "$TMP/errpage_args" ] || { ok=0; echo "  error page was started"; }
  [ "$RC" = "0" ] || { ok=0; echo "  exit status $RC, expected 0"; }
  under "$ELAPSED" 10 || { ok=0; echo "  took ${ELAPSED}s"; }
  [ $ok = 1 ] && pass "$label" || { fail "$label"; sed 's/^/  | /' "$TMP/out" | head -15; }
}

# ---------------------------------------------------------- A: running app
SEND_TERM=1 run_final ns npm start
check_graceful "A1 ns: PID 1 script, npm-like non-forwarding wrapper -> leaf drains once, exit 0"

SEND_TERM=1 WRAPPER_FWD=1 run_final ns npm start
check_graceful "A2 ns: forwarding (pnpm-like) wrapper -> leaf handler still runs exactly once"

SEND_TERM=1 run_final ns node "$LEAF"
check_graceful "A3 ns: CMD is the server itself"

SEND_TERM=1 PM_NAME=pnpm PACKAGE_MANAGER_FIELD=pnpm@9.0.0 WRAPPER_FWD=1 run_final ns npm start
check_graceful "A4 ns: packageManager pnpm (CMD npm rewritten to pnpm)"
SEND_TERM=1 PM_NAME=yarn PACKAGE_MANAGER_FIELD=yarn@1.22.22 run_final ns npm start
check_graceful "A4 ns: packageManager yarn (CMD npm rewritten to yarn)"

SEND_TERM=1 run_final host npm start
check_graceful "A1 host: real app_group_members, non-forwarding wrapper"
SEND_TERM=1 WRAPPER_FWD=1 run_final host npm start
check_graceful "A2 host: real app_group_members, forwarding wrapper"

# A5 real package managers: a throwaway app started by the real binary. The
# shim is not needed because the host case uses the real /proc reader.
if [ "$SKIP_REAL_PM" = 1 ]; then
  echo "SKIP (explicit SKIP_REAL_PM=1): A5 real package managers"
else
  APP="$TMP/realapp"
  mkdir -p "$APP"
  cat > "$APP/server.js" <<'JS'
const fs = require('fs');
const d = process.env.STUB_DIR;
setInterval(() => {}, 1000);
process.on('SIGTERM', () => {
  fs.appendFileSync(d + '/term_count', 'x\n');
  setTimeout(() => { fs.writeFileSync(d + '/marker', 'drained'); process.exit(0); }, 1500);
});
fs.writeFileSync(d + '/leaf_started', '1');
JS
  for pm in npm yarn pnpm berry; do
    echo '{"name":"realapp","version":"1.0.0","scripts":{"start":"node server.js"}}' > "$APP/package.json"
    case "$pm" in
      npm) bin=(npm start) ;;
      yarn) bin=(yarn start) ;;
      pnpm) bin=(corepack pnpm start) ;;
      berry) bin=(corepack yarn@4.5.0 start); : > "$APP/yarn.lock"; printf "nodeLinker: node-modules\n" > "$APP/.yarnrc.yml"; (cd "$APP" && corepack yarn@4.5.0 install > /dev/null 2>&1) ;;
    esac
    if ! command -v "${bin[0]}" > /dev/null 2>&1; then
      fail "A5 real $pm: ${bin[0]} not found"
      continue
    fi
    rm -f "$TMP"/{term_count,marker,leaf_started}
    # Real binaries: keep the stub node/pm out of PATH, run the host-mode block.
    ( cd "$APP" && PATH="$TMP/bin2:$ORIG_PATH" exec bash "$TMP/final_host.sh" "${bin[@]}" > "$TMP/out" 2>&1 ) &
    pid=$!
    for _ in $(seq 1 100); do [ -f "$TMP/leaf_started" ] && break; sleep 0.1; done
    sleep 0.5
    if [ ! -f "$TMP/leaf_started" ]; then
      fail "A5 real $pm: app did not start (Corepack download failed?)"
      kill -KILL "$pid" 2>/dev/null
      sed 's/^/  | /' "$TMP/out" | head -8
      continue
    fi
    kill -TERM "$pid"
    wait "$pid"
    RC=$?
    if [ -f "$TMP/marker" ] && [ "$(terms)" = "1" ] && { [ "$RC" = "0" ] || [ "$RC" = "143" ]; }; then
      pass "A5 real $pm ($("${bin[@]:0:$((${#bin[@]} - 1))}" --version 2>/dev/null | head -1)): server handler ran exactly once, drained, exit $RC"
    else
      fail "A5 real $pm: marker=$([ -f "$TMP/marker" ] && echo yes || echo no) handlers=$(terms) rc=$RC"
      sed 's/^/  | /' "$TMP/out" | head -8
    fi
  done
fi

# ------------------------------------------------------ B: exit 143 on TERM
SEND_TERM=1 TERM_EXIT=143 run_final ns node "$LEAF"
if [ "$RC" = "143" ] && [ ! -f "$TMP/errpage_args" ]; then
  pass "B ns: app exits 143 on TERM -> script exits 143, no error page"
else
  fail "B ns: rc=$RC errpage=$(cat "$TMP/errpage_args" 2>/dev/null)"
fi

# ------------------------- C/D: no signal, app exits by itself (regression)
SEND_TERM=0 LEAF_MODE=exit LEAF_EXIT=1 run_final ns node "$LEAF"
if [ "$(cat "$TMP/errpage_args" 2>/dev/null)" = "/runner/loading-server.js error-page.html failed" ]; then
  pass "C ns: app crashes (exit 1) without a signal -> error page is started"
else
  fail "C ns: error page args='$(cat "$TMP/errpage_args" 2>/dev/null)' rc=$RC"
fi
SEND_TERM=0 LEAF_MODE=exit LEAF_EXIT=0 run_final ns node "$LEAF"
if [ "$RC" = "0" ] && [ ! -f "$TMP/errpage_args" ]; then
  pass "D ns: app exits 0 without a signal -> script exits 0, no error page"
else
  fail "D ns: rc=$RC errpage=$(cat "$TMP/errpage_args" 2>/dev/null)"
fi

# ------------------------------------------ E: TERM during the build phase
rm -f "$TMP"/{build_started,errpage_args}
export PATH="$TMP/bin:$ORIG_PATH"
START=$(date +%s.%N)
SOURCE_URL="s3://bucket/not-a-zip.txt" SEND_TERM=1 WAIT_FILE=build_started \
  timeout 25 unshare -rpf bash -c '(while [ ! -f "$STUB_DIR/$WAIT_FILE" ]; do sleep 0.1; done; sleep 0.3; kill -TERM 1) & exec bash "$0" "$@"' "$TMP/entrypoint_sandbox.sh" npm start > "$TMP/out" 2>&1
RC=$?
ELAPSED=$(awk -v a="$START" -v b="$(date +%s.%N)" "BEGIN{printf \"%.1f\", b-a}")
export PATH="$ORIG_PATH"
if [ -f "$TMP/build_started" ] && [ "$RC" = "143" ] && under "$ELAPSED" 8; then
  pass "E ns: TERM during a 30 s build -> exit 143 after ${ELAPSED}s (not the full build), loading-server stub stopped with it"
else
  fail "E ns: build_started=$([ -f "$TMP/build_started" ] && echo yes || echo no) rc=$RC elapsed=${ELAPSED}s"
  sed 's/^/  | /' "$TMP/out" | head -15
fi

# ------------------------------------------ F: loading-server as PID 1
START=$(date +%s.%N)
PORT=0 timeout 15 unshare -rpf bash -c '(sleep 1; kill -TERM 1) & exec "$0" "$1" "$2" "$3"' "$REAL_NODE" "$LOADING" error-page.html failed > "$TMP/out" 2>&1
RC=$?
ELAPSED=$(awk -v a="$START" -v b="$(date +%s.%N)" "BEGIN{printf \"%.1f\", b-a}")
if [ "$RC" = "0" ] && under "$ELAPSED" 4; then
  pass "F ns: loading-server.js (failed state) as PID 1 exits 0 on TERM after ${ELAPSED}s"
else
  fail "F ns: rc=$RC elapsed=${ELAPSED}s"
fi

# --------------------------------------------------- G: static Dockerfile checks
if grep -qE '^ENTRYPOINT \[ "/sbin/tini", "--", "/runner/docker-entrypoint.sh" \]' "$DOCKERFILE"; then
  pass "G ENTRYPOINT is /sbin/tini -- /runner/docker-entrypoint.sh (no -g)"
else
  fail "G ENTRYPOINT is not plain tini in front of the entrypoint script"
fi
APK_LINE=$(grep -E '^RUN apk add --no-cache' "$DOCKERFILE")
for pkg in tini setpriv; do
  echo "$APK_LINE" | grep -qE "(^| )${pkg}( |\$)" && pass "G apk add line installs $pkg" || fail "G apk add line installs $pkg"
done
if grep -v '^[[:space:]]*#' "$ENTRYPOINT" | grep -q 'runuser'; then
  fail "G scripts/docker-entrypoint.sh still contains runuser"
else
  pass "G scripts/docker-entrypoint.sh contains no runuser"
fi

# ----------------------------------------------------------- I: launcher env
SEND_TERM=0 LEAF_MODE=exit LEAF_EXIT=0 run_final ns node "$LEAF"
ARGS=$(cat "$TMP/setpriv_args" 2>/dev/null)
ENVS=$(tr '\n' ' ' < "$TMP/setpriv_env" 2>/dev/null)
if [ "$ARGS" = "--reuid=node --regid=node --init-groups" ] && [ "$ENVS" = "HOME=/home/node LOGNAME=node SHELL=/bin/ash USER=node " ]; then
  pass "I launcher: setpriv --reuid=node --regid=node --init-groups with HOME/SHELL from passwd, USER=LOGNAME=node"
else
  fail "I launcher: args='$ARGS' env='$ENVS'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
