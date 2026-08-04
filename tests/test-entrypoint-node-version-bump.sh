#!/usr/bin/env bash
# tests/test-entrypoint-node-version-bump.sh
#
# Shell regression tests for issue #49: bump the default base image to
# node:24-alpine and bundle alternate Node majors + Corepack so
# docker-entrypoint.sh can honor an app's package.json "engines.node" and
# "packageManager" fields.
#
# Usage:
#   bash tests/test-entrypoint-node-version-bump.sh
#
# Exit code: 0 = all tests pass, 1 = one or more tests failed.
#
# Note: A full integration test would require running the Docker build.
# These tests act as a fast, dependency-free smoke check that the
# Dockerfile changes were not accidentally reverted or misconfigured.

DOCKERFILE="Dockerfile"
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

if [ ! -f "$DOCKERFILE" ]; then
  echo "ERROR: $DOCKERFILE not found. Run this script from the repo root."
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: default base image bumped to node:24-alpine
# ---------------------------------------------------------------------------
assert_contains \
  "ARG NODE_IMAGE defaults to node:24-alpine" \
  "ARG NODE_IMAGE=node:24-alpine" \
  "$DOCKERFILE"

assert_not_contains \
  "node:22-alpine is no longer the default NODE_IMAGE" \
  "ARG NODE_IMAGE=node:22-alpine" \
  "$DOCKERFILE"

# ---------------------------------------------------------------------------
# Test 2: alternate Node majors are bundled via multi-stage COPY (musl-native,
# not a version manager that downloads glibc binaries at runtime)
# ---------------------------------------------------------------------------
assert_contains \
  "node:18-alpine build stage is present" \
  "FROM node:18-alpine AS node18" \
  "$DOCKERFILE"

assert_contains \
  "node:20-alpine build stage is present" \
  "FROM node:20-alpine AS node20" \
  "$DOCKERFILE"

assert_contains \
  "node:22-alpine build stage is present" \
  "FROM node:22-alpine AS node22" \
  "$DOCKERFILE"

assert_contains \
  "node18 userland is copied into /opt/nodejs/18" \
  "COPY --from=node18 /usr/local /opt/nodejs/18" \
  "$DOCKERFILE"

assert_contains \
  "node20 userland is copied into /opt/nodejs/20" \
  "COPY --from=node20 /usr/local /opt/nodejs/20" \
  "$DOCKERFILE"

assert_contains \
  "node22 userland is copied into /opt/nodejs/22" \
  "COPY --from=node22 /usr/local /opt/nodejs/22" \
  "$DOCKERFILE"

# ---------------------------------------------------------------------------
# Test 3: Corepack is enabled for the default image and every bundled major
# ---------------------------------------------------------------------------
assert_contains \
  "Corepack is enabled for the default image" \
  "RUN corepack enable" \
  "$DOCKERFILE"

assert_contains \
  "Corepack is enabled for the bundled node18 install directory" \
  "/opt/nodejs/18/bin/corepack enable --install-directory /opt/nodejs/18/bin" \
  "$DOCKERFILE"

assert_contains \
  "Corepack is enabled for the bundled node20 install directory" \
  "/opt/nodejs/20/bin/corepack enable --install-directory /opt/nodejs/20/bin" \
  "$DOCKERFILE"

assert_contains \
  "Corepack is enabled for the bundled node22 install directory" \
  "/opt/nodejs/22/bin/corepack enable --install-directory /opt/nodejs/22/bin" \
  "$DOCKERFILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
