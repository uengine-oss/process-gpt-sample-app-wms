FROM node:20-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
# Empty (default) for a standalone deploy at domain root. Set to /wms/ when
# building the image that runs behind process-gpt-vue3's gateway, which
# reaches this app at <tenant>.process-gpt.io/wms — see vite.config.ts.
ARG VITE_BASE_PATH=/
ENV VITE_BASE_PATH=$VITE_BASE_PATH
RUN npm run build

FROM nginx:1.27-alpine

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY docker-entrypoint.d/env.sh /docker-entrypoint.d/50-env.sh
RUN chmod +x /docker-entrypoint.d/50-env.sh

EXPOSE 5273
