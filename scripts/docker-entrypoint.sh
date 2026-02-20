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

  echo "ensure staging dir is empty"
  rm -rf /usercontent/* /usercontent/.[!.]*
  if [[ ! -z "$GITHUB_TOKEN" ]]; then
    echo "cloning https://***@github.com${path}"
    git clone https://$GITHUB_TOKEN@github.com${path} /usercontent/
  else
    echo "cloning https://github.com${path}"
    git clone https://github.com${path} /usercontent/
  fi
  git config --global --add safe.directory /usercontent
  if [[ ! -z "$branch" ]]; then
    echo "checking out branch: $branch"
    git -C /usercontent/ checkout "$branch"
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
  echo "Loading environment variables from application config service '$CONFIG_SVC'"
  config_env_output=$(npx -y @osaas/cli@latest web config-to-env "$CONFIG_SVC" 2>&1)
  if [ $? -eq 0 ]; then
    eval "$config_env_output"
  else
    echo "Warning: Failed to load config from application config service: $config_env_output"
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

cd /usercontent/ && \
  npm install -g husky && \
  npm install --include=dev && \
  npm run --if-present build && \
  npm run --if-present build:app
BUILD_EXIT=$?

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
