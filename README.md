# app-frontend

HTML + JS plano servido por Nginx. Consume el backend `app-backend` para verificar si un número es primo o si una palabra es palíndromo.

Nota: a pesar del nombre histórico del README, esta app es HTML/Nginx, no Python — se eligió por simplicidad para validar Docker y GitOps.

## Estructura

- `index.html` — forms + fetch a `/api/is-prime` y `/api/is-palindrome`.
- `nginx.conf` — sirve `index.html`, expone `/health`, y hace `proxy_pass /api/ → http://app-backend:8080/`.
- `Dockerfile` — `nginx:alpine` con los dos archivos copiados.

El nombre del host `app-backend` se resuelve tanto en docker-compose (por el nombre de servicio) como en Kubernetes (por el `Service`), siempre que ambas apps vivan en la misma red/namespace.

## Correr con Docker

```
docker build -t app-frontend:dev .
docker run --rm -p 8081:80 app-frontend:dev
```

Para que el proxy a `/api/` funcione necesitás que el contenedor `app-backend` esté accesible. Usá el `docker-compose.yml` de la raíz del workspace.

## En el contexto del PoC

Manifests de Kubernetes y Applications de ArgoCD viven en el repo `gitops-apps`.
