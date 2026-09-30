#!/usr/bin/env bash
# tests/test-dockerfile-native-build-toolchain.sh
#
# Shell regression tests for issue #60: the Alpine-based runner image must
# ship python3/make/g++ (the standard node-gyp toolchain on musl) so that
# npm packages with native bindings (e.g. better-sqlite3, bcrypt, sharp)
# can compile from source when no musl-x64 prebuilt binary is available for
# the exact bundled Node major.
#
# Usage:
#   bash tests/test-dockerfile-native-build-toolchain.sh
#
# Exit code: 0 = all tests pass, 1 = one or more tests failed.
#
# Strategy: grep-based static assertions against the Dockerfile, matching
# the style of the other tests/test-*.sh files in this repo. This is a
# fast, dependency-free smoke check that the toolchain packages were not
# accidentally reverted or dropped. It does NOT prove an actual native
# `npm install` succeeds inside the built image -- see
# tests/smoke-test-native-module-install.sh for a Docker-based test that
# does, which this repo's existing test suite does not otherwise attempt
# for any Dockerfile change (no Docker daemon is assumed available here).

DOCKERFILE="Dockerfile"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$DOCKERFILE" ]; then
  echo "ERROR: $DOCKERFILE not found. Run this script from the repo root."
  exit 1
fi

# ---------------------------------------------------------------------------
# Test: the apk add line that installs the runner's base tooling also
# installs the node-gyp build toolchain (python3, make, g++).
# ---------------------------------------------------------------------------
APK_LINE=$(grep -E '^RUN apk add --no-cache' "$DOCKERFILE" || true)

if [ -z "$APK_LINE" ]; then
  fail "apk add --no-cache line found in Dockerfile (pattern not found)"
else
  pass "apk add --no-cache line found in Dockerfile"

  for pkg in python3 make g++; do
    # Escape regex metacharacters in the package name (g++ contains
    # literal '+' chars) before building a word-boundary-ish match, so
    # this doesn't false-pass on a substring match.
    escaped_pkg=$(printf '%s' "$pkg" | sed 's/[.[\*^$+?(){}|\\]/\\&/g')
    if echo "$APK_LINE" | grep -qE "(^| )${escaped_pkg}( |$)"; then
      pass "apk add line installs '$pkg'"
    else
      fail "apk add line installs '$pkg' (not found in: $APK_LINE)"
    fi
  done

  # Pre-existing packages must still be present -- this is an addition,
  # not a replacement.
  for pkg in bash git runuser aws-cli curl jq; do
    if echo "$APK_LINE" | grep -qE "(^| )${pkg}( |$)"; then
      pass "apk add line still installs pre-existing package '$pkg'"
    else
      fail "apk add line still installs pre-existing package '$pkg' (not found in: $APK_LINE)"
    fi
  done
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
