FROM nginx:1.27-alpine
ARG GIT_SHA=local
RUN printf '<!doctype html><title>tflab</title><h1>Hello from Azure Container Apps</h2><p>Build <code>%s</code></p>\n' "$GIT_SHA" \
      > /usr/share/nginx/html/index.html
EXPOSE 80
