# cvm-dd-platform (PoC)

Deploys **DefectDojo Community Edition** into an existing **AKS** cluster using **Azure DevOps pipelines only**.

## Required pipeline variables

Set these variables in the pipeline UI (or variable groups), not in code:

- `AZURE_SERVICE_CONNECTION`: Azure DevOps Service Connection name used by `AzureCLI@2`
- `AKS_RG`: Resource group containing the AKS cluster
- `AKS_NAME`: AKS cluster name
- `DD_HOST`: Ingress hostname for DefectDojo (PoC example: `defectdojo.local`)

## What the pipeline does

Pipeline file: `azure-pipelines.yml`

- **Validate stage** (runs on PR + main)
  - Verifies required files exist
  - Runs `helm lint` against the pinned DefectDojo chart using `k8s/defectdojo-values.yaml`

- **Deploy stage** (runs on main only)
  - Logs in to Azure via `AzureCLI@2` (service connection)
  - Gets AKS admin kubeconfig (`az aks get-credentials --admin`)
  - Installs/updates DefectDojo via Helm into namespace `defectdojo`

## Deployment details (PoC defaults)

- Namespace: `defectdojo`
- Helm chart repo: `https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts`
- Chart: `defectdojo/defectdojo`
- Pinned chart version: `1.9.5`
- In-cluster dependencies: **PostgreSQL** and **Valkey (Redis-compatible)** via chart dependencies
- Persistence:
  - PostgreSQL PVC: `10Gi`
  - DefectDojo media PVC: `10Gi`
- Ingress:
  - class: `nginx`
  - host: `DD_HOST`
  - TLS: disabled (PoC)

## Lessons learned (stability)

- If you see intermittent `503 Service Temporarily Unavailable (nginx)` on pages like `/change_password`, check `kubectl describe pod -n defectdojo -l defectdojo.org/component=django`.
- If `uwsgi` shows `OOMKilled` or `CrashLoopBackOff`, increase `django.uwsgi.resources` (this repo defaults to `512Mi` request / `1Gi` limit in `k8s/defectdojo-values.yaml`).
- Probes are patched by `scripts/install-defectdojo.ps1` to avoid flapping under load (uWSGI `tcpSocket` probes, nginx readiness self-check).

## DD API token (PoC)

After deployment, `scripts/post-install-bootstrap.ps1` attempts to:

1. Read the admin password from the Kubernetes secret `defectdojo` in namespace `defectdojo`.
2. Call `http://<DD_HOST>/api/v2/api-token-auth/` to obtain an API token.
3. Publish it as an Azure DevOps output variable:

- `DD_API_TOKEN`

If the agent cannot reach `DD_HOST` yet (DNS/LB still provisioning), the script falls back to:

- best-effort UI reachability check
- instructions to create an API token manually in the DefectDojo UI

### Manual token creation fallback

- Browse to `http://<DD_HOST>`
- Log in as user `admin`
- Create an API v2 token (user menu)
- Store it in Azure DevOps as a **secret variable** (or variable group) named `DD_API_TOKEN` for downstream use

## Downstream import (Central vulnerability management)

Downstream app pipelines that import findings should use the DefectDojo API token:

- Read `DD_API_TOKEN` from a secure variable (preferred for PoC), or from the Deploy job output variable if in the same pipeline.
- Use it as the `Authorization: Token <token>` header when calling the DefectDojo API.

## Scripts

- `scripts/aks-login.ps1`: gets kubeconfig using `az aks get-credentials` and verifies access
- `scripts/install-defectdojo.ps1`: idempotent Helm upgrade/install + rollout wait
- `scripts/post-install-bootstrap.ps1`: best-effort UI check + API token bootstrap
