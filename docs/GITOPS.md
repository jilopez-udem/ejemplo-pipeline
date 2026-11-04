# CI/CD con GitHub Actions + Docker Hub + ArgoCD + minikube

Flujo GitOps completo para la app "Cat Gif of the Day":

```
git push (rama gitops-argocd)
   └─► GitHub Actions
         1. build de la imagen (amd64 + arm64)
         2. push a Docker Hub  → jilopezv1/cat-gif-app:sha-xxxxxxx
         3. commit que actualiza k8s/deployment.yaml con el nuevo tag
   └─► ArgoCD (corriendo en minikube) detecta el commit en Git
         4. sync: aplica k8s/ en el clúster
   └─► Kubernetes descarga la imagen nueva de Docker Hub y hace rolling update
```

> **¿Por qué ArgoCD corre dentro de minikube?** ArgoCD es una aplicación nativa de
> Kubernetes: guarda su estado en CRDs (`Application`, `AppProject`) y ConfigMaps del
> clúster, así que no puede correr como un `docker run` suelto. Con el driver `docker`,
> minikube ya es un contenedor en tu máquina, y ArgoCD corre como pods dentro de él.

## Estructura

| Archivo | Para qué sirve |
|---|---|
| `Dockerfile` | Imagen con Python 3.12 + gunicorn, usuario sin privilegios |
| `.github/workflows/docker-gitops.yml` | Pipeline CI: build, push y actualización del manifiesto |
| `k8s/namespace.yaml`, `k8s/deployment.yaml`, `k8s/service.yaml` | Estado deseado del clúster (lo que ArgoCD sincroniza) |
| `argocd/application.yaml` | Le dice a ArgoCD qué repo/rama/carpeta vigilar |

## 0. Requisitos

- Docker Desktop, `minikube`, `kubectl`
- Cuenta de Docker Hub (`jilopezv1`)
- Opcional: CLI de ArgoCD → `brew install argocd`

## 1. Configurar secretos en GitHub (una sola vez)

1. Docker Hub → *Account settings* → *Personal access tokens* → **Generate new token**
   con permisos *Read & Write*.
2. GitHub → repo `ejemplo-pipeline` → *Settings* → *Secrets and variables* → *Actions* →
   **New repository secret**:
   - `DOCKERHUB_USERNAME` = `jilopezv1`
   - `DOCKERHUB_TOKEN` = el token del paso 1
3. *Settings* → *Actions* → *General* → *Workflow permissions* → **Read and write permissions**
   (el workflow necesita hacer push del manifiesto actualizado).

## 2. Primer push (dispara la primera imagen)

```bash
git push -u origin gitops-argocd
```

Ve a la pestaña **Actions** del repo: verás los jobs `build-and-push` y `update-manifests`.
Al terminar habrá:
- La imagen `jilopezv1/cat-gif-app:sha-xxxxxxx` (y `:latest`) en Docker Hub.
- Un commit `ci: desplegar imagen sha-xxxxxxx` de `github-actions[bot]` en la rama.

## 3. Levantar minikube e instalar ArgoCD

```bash
minikube start

kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd rollout status deploy/argocd-server
```

Abrir la UI (dejar esta terminal abierta):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

- URL: https://localhost:8080 (aceptar el certificado autofirmado)
- Usuario: `admin`
- Contraseña:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo
  ```

## 4. Registrar la aplicación en ArgoCD

```bash
kubectl apply -f argocd/application.yaml
```

En la UI aparece `cat-gif-app`. Como tiene `syncPolicy.automated`, ArgoCD crea el
namespace `cat-gif`, el Deployment y el Service sin intervención. Estado esperado:
**Synced / Healthy**.

Ver la app:

```bash
minikube service cat-gif-app -n cat-gif
# o bien
kubectl -n cat-gif port-forward svc/cat-gif-app 5001:80   # → http://localhost:5001
```

El pie de página muestra **Versión: sha-xxxxxxx**, el mismo tag que construyó GitHub Actions.

## 5. La demo: un cambio de código llega solo al clúster

1. Cambia algo visible, por ejemplo el título en `templates/index.html`:
   ```html
   <h1>Cat Gif of the Day — Gestión de la Configuración</h1>
   ```
2. Commit y push:
   ```bash
   git commit -am "Cambiar título" && git push
   ```
3. Observa en orden:
   - **GitHub Actions**: build + push + commit del bot (≈2–3 min por el build multi-arquitectura).
   - **Docker Hub**: aparece el nuevo tag.
   - **ArgoCD**: detecta el commit (polling cada ~3 min; para no esperar, botón **Refresh**
     o `argocd app get cat-gif-app --refresh`), pasa a *OutOfSync* → *Syncing* → *Synced*.
   - **Kubernetes**: `kubectl -n cat-gif get pods -w` muestra el rolling update.
4. Recarga la app: nuevo título y nueva versión en el pie.

## 6. Experimentos extra para clase

- **Self-heal**: `kubectl -n cat-gif scale deploy/cat-gif-app --replicas=5`.
  ArgoCD lo devuelve a 2 réplicas en segundos: Git es la fuente de verdad.
- **Cambio solo de infraestructura**: edita `replicas: 3` en `k8s/deployment.yaml` y haz push.
  El workflow **no** corre (`paths-ignore: k8s/**`), pero ArgoCD sí sincroniza.
- **Rollback**: `git revert <commit-del-bot> && git push` → ArgoCD vuelve a la imagen anterior.
  También desde la UI: *History and rollback*.
- **Prune**: borra `k8s/service.yaml` y haz push → ArgoCD elimina el Service del clúster.

## Problemas comunes

| Síntoma | Causa / solución |
|---|---|
| Job `update-manifests` falla con 403 | Falta *Read and write permissions* (paso 1.3) |
| Login a Docker Hub falla | Revisar los secretos `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` |
| Pods en `ImagePullBackOff` | La imagen aún no existe en Docker Hub o el repo de Docker Hub es privado |
| `exec format error` en el pod | Imagen solo amd64 en un Mac Apple Silicon; el workflow ya construye `linux/arm64` |
| ArgoCD tarda en ver el cambio | Polling de 3 min; usar **Refresh** |

## Limpieza

```bash
kubectl delete -f argocd/application.yaml   # el finalizer borra también los recursos de la app
kubectl delete namespace cat-gif argocd
minikube stop
```
