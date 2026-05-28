FROM nginx:1.27-alpine

# Aplica los ultimos parches de seguridad del repo de Alpine.
# Trivy pegaba por CVEs HIGH/CRITICAL con fix en openssl, libxml2, musl,
# nghttp2 y zlib que la imagen upstream todavia no incorporo.
RUN apk --no-cache upgrade

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
