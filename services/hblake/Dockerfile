FROM node:lts-alpine AS builder

RUN apk add --no-cache git

RUN git clone https://github.com/hsimah-services/hblake.git /app

WORKDIR /app

RUN npm ci && npm run build

FROM nginx:alpine

COPY --from=builder /app/dist /usr/share/nginx/html
