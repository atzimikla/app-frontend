# Design — Approval gate manual en BumpGitops vía templates centralizados

- **Fecha:** 2026-06-24
- **Rama app-frontend:** `feat/bump-gitops-approval`
- **Repos afectados:** `platform-pipelines` (centralizado) + `app-frontend` (consumidor)

## Objetivo

Que el deploy de `app-frontend` a `gitops-apps` (stage `BumpGitops`) quede detrás
de una **aprobación manual a nivel de Azure DevOps**, reutilizando los templates
centralizados de `platform-pipelines` en lugar de los templates locales que hoy
viven en `app-frontend/pipelines/`.

El cambio en `platform-pipelines` debe ser **retrocompatible**: `app-backend` y
cualquier otro consumidor que no pida el gate deben seguir funcionando sin tocar
nada.

## Contexto actual

- `app-frontend/azure-pipelines.yml` define dos stages (`BuildAndPush` →
  `BumpGitops`) consumiendo templates **locales** (`app-frontend/pipelines/*.yml`).
  No consume `platform-pipelines`.
- `app-frontend/azure-pipelines-validate.yml` corre validación de PRs usando el
  template local `pipelines/validate.yml`.
- `platform-pipelines` ya expone templates reutilizables equivalentes
  (`static-app-ci.yml`, `static-app-validate.yml`) y **ya tiene el patrón de
  approval** en `templates/pipelines/iac/terraform-stack.yml`: un `deployment`
  job con `environment:`, donde Azure DevOps aplica el gate de aprobación manual.

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Cómo agregar el approval al template | Parámetro **opcional** `bumpEnvironment` (retrocompatible) |
| Mecanismo de aprobación | **Environment + Approvals & checks** (mismo patrón que `terraform-stack.yml`) |
| Wiring en app-frontend | Reemplazar `azure-pipelines.yml` por patrón `extends` — **solo en la rama feature** |
| Limpieza | **Total**: migrar también `azure-pipelines-validate.yml` y borrar toda la carpeta `pipelines/` local |
| `ref` de platform-pipelines | `refs/heads/master` (el cambio es retrocompatible, no requiere rama aparte) |
| Parte manual de Azure | Registrar una **nueva definición de pipeline** en el portal apuntando a la rama feature, sin tocar el pipeline existente sobre `develop` |

## Arquitectura de la solución

### 1. platform-pipelines (centralizado, en `master`)

**a) Nuevo steps-template `templates/steps/gitops/bump-steps.yml`**

Extrae los 3 steps que hoy viven inline en el job `bump-gitops.yml`
(`checkout: none` + `install-kustomize` + `bump-image-tag`) a un steps-template
reutilizable. Esto permite usarlos idénticos tanto en un `job:` clásico como en
un `deployment:` job sin duplicar lógica.

Parámetros: `appName`, `ecrImageUri`, `imageTag`, `overlayPath`, `gitopsRepo`,
`gitopsBranch` (passthrough a `bump-image-tag.yml`).

**b) `templates/jobs/apps/bump-gitops.yml` — bifurcación condicional**

- Nuevo parámetro `bumpEnvironment` (`string`, default `''`).
- El bloque `variables` (grupo `gitops-bot-creds` + `imageShaTag` desde
  `stageDependencies.BuildAndPush...`) es idéntico en ambas ramas.
- `${{ if eq(parameters.bumpEnvironment, '') }}` → `- job: BumpGitops` que usa
  `bump-steps.yml`. **Comportamiento idéntico al actual.**
- `${{ if ne(parameters.bumpEnvironment, '') }}` → `- deployment: BumpGitops`
  con `environment: ${{ parameters.bumpEnvironment }}` y
  `strategy.runOnce.deploy.steps` que usa el **mismo** `bump-steps.yml`.

**c) `templates/pipelines/apps/static-app-ci.yml`**

- Nuevo parámetro `bumpEnvironment` (`string`, default `''`), pasado al job
  `bump-gitops.yml`.

**d) `examples/static-app-ci.yml`**

- Documentar el nuevo parámetro `bumpEnvironment` con el ejemplo de frontend.

### 2. app-frontend (rama `feat/bump-gitops-approval`, limpieza total)

**a) `azure-pipelines.yml`** → patrón `extends`:

```yaml
resources:
  repositories:
    - repository: platform-pipelines
      type: github
      name: atzimikla/platform-pipelines
      endpoint: '<github-service-connection>'
      ref: refs/heads/master

trigger:
  branches:
    include: [develop]
pr: none

extends:
  template: templates/pipelines/apps/static-app-ci.yml@platform-pipelines
  parameters:
    appName: 'app-frontend'
    awsServiceConnection: 'aws-ecr-pusher-frontend-oidc'
    ecrRegistry: '875585125966.dkr.ecr.us-east-1.amazonaws.com'
    imageRepo: 'app-frontend'
    overlayPath: 'manifests/app-frontend/overlays/dev'
    bumpEnvironment: 'gitops-frontend-dev'   # activa el approval gate
```

**b) `azure-pipelines-validate.yml`** → patrón `extends`:

```yaml
resources:
  repositories:
    - repository: platform-pipelines
      type: github
      name: atzimikla/platform-pipelines
      endpoint: '<github-service-connection>'
      ref: refs/heads/master

trigger: none
pr:
  branches:
    include: [develop]

extends:
  template: templates/pipelines/apps/static-app-validate.yml@platform-pipelines
  parameters:
    appName: 'app-frontend'
    htmlTarget: 'index.html'
    smokeCommand: 'nginx -t'
    smokeExtraDockerArgs: '--add-host=app-backend:127.0.0.1'
```

**c) Borrar** toda la carpeta `app-frontend/pipelines/`
(`build-and-push.yml`, `bump-gitops.yml`, `validate.yml`) — queda 100%
centralizado, sin templates locales huérfanos.

### 3. Parte manual en Azure DevOps (runbook)

1. **Crear Environment** `gitops-frontend-dev` (Pipelines → Environments → New).
2. **Approval check**: Environment → Approvals and checks → Approvals → asignar
   aprobador(es) + timeout.
3. **Registrar nueva definición de pipeline** apuntando a `azure-pipelines.yml`
   de la rama `feat/bump-gitops-approval` (New pipeline → GitHub → app-frontend →
   Existing YAML → rama feature). El pipeline existente sobre `develop` no se
   toca.
4. **Ejecutar manualmente**: corre `BuildAndPush` → al llegar a `BumpGitops`
   queda **pausado esperando aprobación** en el Environment; al aprobar, ejecuta
   el bump contra `gitops-apps`.

## Flujo de datos

`BuildAndPush` publica la imagen a ECR y expone `imageShaTag` como output var
(`pushStep.imageShaTag`). `BumpGitops` lee ese SHA vía
`stageDependencies.BuildAndPush.BuildAndPush.outputs['pushStep.imageShaTag']`,
clona `gitops-apps`, hace `kustomize edit set image` sobre el overlay dev,
valida el render y pushea. La única diferencia con el flujo actual es que, con
`bumpEnvironment` seteado, ese job no arranca hasta que un aprobador lo libera en
el Environment de Azure DevOps.

## Manejo de errores / retrocompatibilidad

- **Retrocompat**: con `bumpEnvironment` vacío (default), el render produce el
  `- job: BumpGitops` clásico → `app-backend` y demás consumidores no cambian.
- El gate de aprobación tiene timeout configurable en el Environment; si expira,
  el deployment job se cancela sin pushear a `gitops-apps`.
- El step de push a `gitops-apps` ya tiene retry-on-rebase (3 intentos) para
  tolerar concurrencia — se preserva sin cambios.

## Verificación

- **Lint estructural** de los YAML modificados (no hay runner local de AzDO; la
  validación final la hace el propio Azure DevOps al compilar el pipeline).
- **Retrocompat**: revisar que el `${{ if }}` produce el `job:` clásico cuando
  `bumpEnvironment == ''` (caso `app-backend` / ejemplo sin el param).
- **End-to-end**: la corrida manual en Azure DevOps es la prueba real del gate
  (pausa en `BumpGitops` → aprobación → push a `gitops-apps`).

## Fuera de alcance (YAGNI)

- No se agregan aprobaciones a `BuildAndPush` (solo el bump a gitops).
- No se crea un entorno de prod ni un segundo overlay (sigue siendo dev-only).
- No se modifican los templates ni el pipeline de `app-backend`.
- No se borran los templates locales en `develop`/`main` (la limpieza es solo en
  la rama feature).
