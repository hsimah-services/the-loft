FROM node:lts-alpine AS builder

RUN apk add --no-cache openssh-client git

RUN mkdir -p -m 0700 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts

RUN --mount=type=ssh git clone git@github.com:hsimah-services/hblake.git /app

WORKDIR /app

RUN npm ci && npm run build

FROM nginx:alpine

COPY --from=builder /app/dist /usr/share/nginx/html
