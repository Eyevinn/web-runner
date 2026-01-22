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

if [[ ! -z "$GITHUB_URL" ]]; then
  path="/${GITHUB_URL#*://*/}" && [[ "/${GITHUB_URL}" == "${path}" ]] && path="/"

  echo "ensure staging dir is empty"
  rm -rf /usercontent/* /usercontent/.[!.]*
  if [[ ! -z "$GITHUB_TOKEN" ]]; then
    echo "cloning https://***@github.com${path}"
    git clone https://$GITHUB_TOKEN@github.com${path} /usercontent/
  else
    echo "cloning https://github.com${path}"
    git clone https://github.com${path} /usercontent/
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
  eval `npx -y @osaas/cli@latest web config-to-env $CONFIG_SVC`
fi

cd /usercontent/ && \
  npm install -g husky && \
  npm install --include=dev && \
  npm run --if-present build && \
  npm run --if-present build:app
exec runuser -u node "$@"
