# ---------- Stage 1: build the React app ----------
FROM node:20-alpine AS build
WORKDIR /app

# Install dependencies first so they are cached as their own layer
COPY package.json package-lock.json ./
RUN npm ci

COPY public ./public
COPY src ./src
RUN npm run build

# ---------- Stage 2: nginx serves the static files (non-root) ----------
FROM nginxinc/nginx-unprivileged:1.27-alpine

# The image fills in this template from environment variables at startup
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/build /usr/share/nginx/html

ENV BACKEND_HOST=todo-backend \
    BACKEND_PORT=8080 \
    DNS_RESOLVER=127.0.0.11

EXPOSE 8080
