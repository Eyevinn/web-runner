ARG NODE_IMAGE=node:20-alpine

FROM ${NODE_IMAGE}
RUN apk add --no-cache bash git runuser aws-cli
ENV NODE_ENV=production
WORKDIR /runner
COPY ./scripts ./
VOLUME /usercontent
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]
CMD [ "npm", "start" ]
