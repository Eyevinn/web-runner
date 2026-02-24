#!/bin/bash

STAGING_DIR="/usercontent"

if [ -z "$SOURCE_URL" ] && [ -z "$GITHUB_URL" ]; then
  echo "SOURCE_URL or GITHUB_URL must be set. Exiting."
  exit 1
fi

if [[ ! -z "$SOURCE_URL" ]] && [[ "$SOURCE_URL" =~ ^https?://github\.com/ ]]; then
  GITHUB_URL="$SOURCE_URL"
elif [[ ! -z "$SOURCE_URL" ]] && [[ "$SOURCE_URL" =~ ^s3://.*$ ]]; then
  S3_URL="$SOURCE_URL"
fi

node /runner/loading-server.js &
LOADING_PID=$!
trap 'kill $LOADING_PID 2>/dev/null; wait $LOADING_PID 2>/dev/null' EXIT

if [[ ! -z "$GITHUB_URL" ]]; then
  path="/${GITHUB_URL#*://*/}" && [[ "/${GITHUB_URL}" == "${path}" ]] && path="/"

  # Extract branch from URL fragment (e.g. #feat/seo-meta-fix-sprint/)
  branch=""
  if [[ "$GITHUB_URL" == *"#"* ]]; then
    branch="${GITHUB_URL#*#}"
    branch="${branch%/}"  # strip trailing slash if present
    path="${path%%#*}"    # remove fragment from path
  fi

  git config --global --add safe.directory /usercontent

  if [ -d "/usercontent/.git" ]; then
    # PVC case: incremental update
    echo "existing repo found, fetching updates"
    git -C /usercontent/ fetch origin
    if [[ ! -z "$branch" ]]; then
      echo "resetting to origin/$branch"
      git -C /usercontent/ checkout "$branch" 2>/dev/null || true
      git -C /usercontent/ reset --hard "origin/$branch"
    else
      # Detect default branch
      default_branch=$(git -C /usercontent/ symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
      if [ -z "$default_branch" ]; then
        default_branch="main"
      fi
      echo "resetting to origin/$default_branch"
      git -C /usercontent/ reset --hard "origin/$default_branch"
    fi
    echo "cleaning untracked files (preserving node_modules and .next)"
    git -C /usercontent/ clean -fd --exclude=node_modules --exclude=.next
  else
    # Fresh clone
    echo "ensure staging dir is empty"
    rm -rf /usercontent/* /usercontent/.[!.]*
    if [[ ! -z "$GITHUB_TOKEN" ]]; then
      echo "cloning https://***@github.com${path}"
      git clone https://$GITHUB_TOKEN@github.com${path} /usercontent/
    else
      echo "cloning https://github.com${path}"
      git clone https://github.com${path} /usercontent/
    fi
    if [[ ! -z "$branch" ]]; then
      echo "checking out branch: $branch"
      git -C /usercontent/ checkout "$branch"
    fi
  fi
elif [[ ! -z "$S3_URL" ]]; then
  if [[ "$S3_URL" =~ ^.*\.zip$ ]]; then
    echo "downloading $S3_URL"
    if [[ ! -z "$S3_ENDPOINT_URL" ]]; then
      echo "using S3 endpoint URL: $S3_ENDPOINT_URL"
      aws s3 cp --endpoint-url "$S3_ENDPOINT_URL" "$S3_URL" /usercontent.zip
    else
      aws s3 cp "$S3_URL" /usercontent.zip
    fi
    echo "unzipping /usercontent.zip"
    unzip -q /usercontent.zip -d /usercontent/ && rm -f /usercontent.zip
    # Remove any node_modules directory if it exists
    rm -rf /usercontent/node_modules
  fi
fi

chown node:node -R /usercontent/

if [[ ! -z "$OSC_ACCESS_TOKEN" ]] && [[ ! -z "$CONFIG_SVC" ]]; then
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  config_env_output=$(npx -y @osaas/cli@latest web config-to-env "$CONFIG_SVC" 2>&1)
  if [ $? -eq 0 ]; then
    eval "$config_env_output"
    var_count=$(echo "$config_env_output" | grep -c "^export " || true)
    echo "[CONFIG] Loaded $var_count environment variable(s) — available for build and runtime"
  else
    echo "[CONFIG] Warning: Failed to load config from application config service."
    echo "[CONFIG] Output: $config_env_output"
    if echo "$config_env_output" | grep -qi "expired\|unauthorized\|401"; then
      echo "[CONFIG] Action required: Your OSC_ACCESS_TOKEN may have expired."
      echo "[CONFIG] Use the 'refresh-app-config' MCP tool to issue a fresh token."
    fi
  fi
fi

if [[ -z "$APP_URL" ]] && [[ ! -z "$OSC_HOSTNAME" ]]; then
  export APP_URL="https://$OSC_HOSTNAME"
  echo "APP_URL set to $APP_URL"
fi

if [[ -z "$AUTH_URL" ]] && [[ ! -z "$OSC_HOSTNAME" ]]; then
  if [[ ! -z "$AUTH_PATH" ]]; then
    export AUTH_URL="https://$OSC_HOSTNAME$AUTH_PATH"
  else
    export AUTH_URL="https://$OSC_HOSTNAME/api/auth"
  fi
  echo "AUTH_URL set to $AUTH_URL"
fi

WORK_DIR="/usercontent"
if [[ ! -z "$SUB_PATH" ]]; then
  WORK_DIR="/usercontent/$SUB_PATH"
  if [[ ! -d "$WORK_DIR" ]]; then
    echo "Error: SUB_PATH directory '$WORK_DIR' does not exist"
    exit 1
  fi
  echo "Using SUB_PATH: $SUB_PATH (working directory: $WORK_DIR)"
fi

# Set up cache directories on persistent volume if available
if [ -w "/data" ]; then
  mkdir -p /data/node_modules /data/next-cache
  # Ensure the node user owns PVC cache directories to prevent EACCES at runtime
  chown -R node:node /data/next-cache 2>/dev/null || true
  chown -R node:node /data/node_modules 2>/dev/null || true

  # Set up .next/cache symlink (next build follows symlinks correctly)
  mkdir -p "$WORK_DIR/.next"
  if [ ! -L "$WORK_DIR/.next/cache" ]; then
    rm -rf "$WORK_DIR/.next/cache"
    ln -s /data/next-cache "$WORK_DIR/.next/cache"
  fi
fi

# Check if npm install can be skipped (lockfile unchanged + cached node_modules)
LOCKFILE_HASH=""
if [ -f "$WORK_DIR/package-lock.json" ]; then
  LOCKFILE_HASH=$(sha256sum "$WORK_DIR/package-lock.json" | cut -d' ' -f1)
fi
CACHED_HASH=""
if [ -f "/data/.lockfile-hash" ]; then
  CACHED_HASH=$(cat /data/.lockfile-hash)
fi

cd "$WORK_DIR"
npm install -g husky 2>/dev/null || true

# Restore node_modules from PVC cache if lockfile unchanged.
# Note: we do NOT symlink node_modules because npm's reify step removes
# symlinks ("Removing non-directory") and creates a real directory,
# defeating the cache. Instead we copy from the PVC backup.
if [ -w "/data" ] && [ "$(ls -A /data/node_modules 2>/dev/null)" ] && [ "$LOCKFILE_HASH" = "$CACHED_HASH" ] && [ -n "$LOCKFILE_HASH" ]; then
  echo "package-lock.json unchanged, restoring node_modules from cache"
  rm -rf "$WORK_DIR/node_modules"
  cp -a /data/node_modules "$WORK_DIR/node_modules"
else
  echo "running npm install"
  npm install --include=dev
  # Cache node_modules and lockfile hash to PVC
  if [ -n "$LOCKFILE_HASH" ] && [ -w "/data" ]; then
    echo "$LOCKFILE_HASH" > /data/.lockfile-hash
    echo "caching node_modules to PVC"
    rm -rf /data/node_modules
    cp -a "$WORK_DIR/node_modules" /data/node_modules
  fi
fi

npm run --if-present build
npm run --if-present build:app
BUILD_EXIT=$?

if [ $BUILD_EXIT -eq 0 ]; then
  # Signal readiness for health checks
  mkdir -p "$WORK_DIR/public"
  echo "OK" > "$WORK_DIR/public/healthz"
fi

chown node:node -R /usercontent/

kill $LOADING_PID 2>/dev/null
wait $LOADING_PID 2>/dev/null
trap - EXIT

if [ $BUILD_EXIT -ne 0 ]; then
  echo "Build failed with exit code $BUILD_EXIT"
  exec node /runner/loading-server.js error-page.html
fi

runuser -u node "$@"
APP_EXIT=$?

if [ $APP_EXIT -ne 0 ]; then
  echo "Application exited with code $APP_EXIT"
  exec node /runner/loading-server.js error-page.html
fi
