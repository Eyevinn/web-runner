#!/bin/bash

if [ -z "$GITHUB_URL" ]; then
  echo "GITHUB_URL is not set. Exiting."
  exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
  echo "GITHUB_TOKEN is not set. Exiting."
  exit 1
fi

STAGING_DIR="/usercontent"
path="/${GITHUB_URL#*://*/}" && [[ "/${GITHUB_URL}" == "${path}" ]] && path="/"

echo "cloning https://***@github.com${path}"
git clone https://$GITHUB_TOKEN@github.com${path} /usercontent/
chown node:node -R /usercontent/
cd /usercontent/ && \
  npm install -g husky && \
  npm install && \
  npm run --if-present build && \
  npm run --if-present build:app

exec runuser -u node "$@"