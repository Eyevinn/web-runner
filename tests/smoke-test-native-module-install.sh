#!/usr/bin/env bash
# tests/smoke-test-native-module-install.sh
#
# Docker-based smoke test for issue #60: builds the runner image from this
# repo's Dockerfile and confirms that `npm install` succeeds for a package
# with native bindings (better-sqlite3) that has no musl-x64 prebuilt
# binary for at least one of the bundled Node majors -- the exact failure
# mode reported in the issue:
#
#   npm error prebuild-install warn install No prebuilt binaries found
#     (target=24.19.0 runtime=node arch=x64 libc=musl platform=linux)
#   npm error gyp ERR! stack Error: not found: make
#
# This is a real end-to-end check (unlike the static grep-based assertions
# in tests/test-dockerfile-native-build-toolchain.sh) but requires a local
# Docker daemon, so it is opt-in / manual rather than assumed available in
# every environment this repo's test suite runs in.
#
# Usage:
#   bash tests/smoke-test-native-module-install.sh
#
# Exit codes:
#   0 = native module installed successfully inside the built image
#   1 = build or install failed
#   2 = skipped, no Docker daemon available in this environment

set -euo pipefail

IMAGE_TAG="web-runner-native-build-smoke-test"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found on PATH; cannot run this smoke test here."
  echo "Run this script in an environment with Docker to verify end-to-end."
  exit 2
fi

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not reachable; cannot run this smoke test here."
  exit 2
fi

echo "Building runner image from Dockerfile (this may take a few minutes)..."
docker build -t "$IMAGE_TAG" .

WORKDIR=$(mktemp -d)
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

cat >"$WORKDIR/package.json" <<'EOF'
{
  "name": "native-module-smoke-test",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "better-sqlite3": "^11.0.0"
  }
}
EOF

echo "Installing better-sqlite3 (requires node-gyp/native compilation) inside the runner image..."
docker run --rm \
  -v "$WORKDIR:/app" \
  -w /app \
  --entrypoint sh \
  "$IMAGE_TAG" \
  -c "npm install --include=dev && node -e \"require('better-sqlite3'); console.log('better-sqlite3 loaded OK')\""

echo ""
echo "PASS: better-sqlite3 (native module) installed and loaded successfully inside the runner image."
