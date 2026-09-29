ARG NODE_IMAGE=node:24-alpine

# Alpine (musl) userlands for older Node LTS majors, bundled alongside the
# default image so docker-entrypoint.sh can honor an app's package.json
# "engines.node" field without any network access at container start.
#
# Why not a version manager (fnm/n) that downloads Node on demand instead?
# The official Node.js releases published on nodejs.org are glibc-linked;
# Alpine uses musl libc, so those binaries do not run without a compat
# layer (e.g. gcompat), and there is no musl build published for every
# version we'd want to offer. Copying the userland straight out of the
# official node:<major>-alpine images sidesteps both problems and needs no
# network fetch when a container starts. The tradeoff is image size: each
# extra major adds its own node binary + npm + corepack (verified locally:
# ~95-100MB per extra major, uncompressed).
FROM node:18-alpine AS node18
FROM node:20-alpine AS node20
FROM node:22-alpine AS node22

FROM ${NODE_IMAGE}
# python3/make/g++ are the standard node-gyp toolchain for Alpine (musl).
# They are required in this *runtime* image, not a discardable builder
# stage: docker-entrypoint.sh runs `npm install` (or pnpm/yarn) for each
# deployed app's own package.json at container start (see the install
# logic in scripts/docker-entrypoint.sh), not at `docker build` time for a
# single known app. Any app dependency with native bindings (e.g.
# better-sqlite3, bcrypt, sharp) that lacks a musl-x64 prebuilt binary for
# the exact bundled Node major falls through to a from-source node-gyp
# build, which needs this toolchain present at that point. A multi-stage
# split (toolchain in a builder, slim final image) does not apply here
# because there is no single build-time npm install to isolate.
RUN apk add --no-cache bash git runuser aws-cli curl jq python3 make g++

# Corepack ships with Node 24 and manages yarn/pnpm per the app's
# package.json "packageManager" field. Enabling it once at build time
# creates the yarn/pnpm/pnpx shims so there's no per-container-start cost;
# Corepack itself still fetches the pinned package manager version on
# first use (network access required at that point). Suppress the
# interactive download prompt since containers run non-interactively.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable

# Bundle the extra Node majors and enable Corepack for each of them too, so
# packageManager detection works no matter which engines.node version is
# selected at runtime.
COPY --from=node18 /usr/local /opt/nodejs/18
COPY --from=node20 /usr/local /opt/nodejs/20
COPY --from=node22 /usr/local /opt/nodejs/22
RUN /opt/nodejs/18/bin/corepack enable --install-directory /opt/nodejs/18/bin \
 && /opt/nodejs/20/bin/corepack enable --install-directory /opt/nodejs/20/bin \
 && /opt/nodejs/22/bin/corepack enable --install-directory /opt/nodejs/22/bin

ENV NODE_ENV=production
WORKDIR /runner
COPY ./scripts ./
VOLUME /data
VOLUME /usercontent
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]
CMD [ "npm", "start" ]
