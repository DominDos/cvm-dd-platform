# Operations (DefectDojo on AKS)

Namespace: `defectdojo`

## Admin credentials

This repo deploys DefectDojo with the admin password injected from Azure DevOps secret variable `DD_ADMIN_PASSWORD`.

If you need to retrieve credentials from the cluster (e.g., variable group lost), inspect secrets created by the Helm release:

```bash
kubectl -n defectdojo get secret -l app.kubernetes.io/instance=defectdojo
kubectl -n defectdojo describe secret <secret-name>
```

Notes:
- Exact secret names/keys can change between chart versions; use label selection and inspect.

## Create an API token (UI)

1. Log in as admin: `https://defectdojo.<YOUR_DOMAIN>/login`
2. Open the user/profile menu.
3. Find **API Key / API Token** (API v2).
4. Generate a token and store it in your secret manager / Azure DevOps variable group for downstream automation.

## Rotate the API token

1. Generate a new token in the UI.
2. Update the consuming pipeline/app secret.
3. Validate automation works with the new token.
4. Revoke/delete the old token.

## Troubleshooting

### Pods stuck in Pending (PVC issues)
Symptoms:
- `kubectl -n defectdojo get pods` shows `Pending`
- `kubectl -n defectdojo describe pod <pod>` shows PVC binding errors

Checks:
```bash
kubectl -n defectdojo get pvc
kubectl -n defectdojo describe pvc <pvc>
kubectl get storageclass
```

Actions:
- Ensure the cluster has a default `StorageClass`, or set `storageClassName`/`storageClass` in `helm/defectdojo/values-dev.yaml`.
- For PoC, `ReadWriteOnce` is usually the most compatible access mode.

### Ingress issues
Symptoms:
- DNS resolves but returns 404/502
- No external IP/hostname on ingress

Checks:
```bash
kubectl -n defectdojo get ingress
kubectl -n ingress-nginx get svc
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=200
```

Actions:
- Confirm `ingressClassName: nginx` matches your NGINX ingress installation.
- Ensure DNS `defectdojo.<YOUR_DOMAIN>` points to the ingress external address.
- If TLS is enabled, ensure the referenced TLS secret exists.

### Database migration issues
Symptoms:
- Web/UI returns errors after deploy
- Jobs/deployments crashloop around migrations

Checks:
```bash
kubectl -n defectdojo get pods
kubectl -n defectdojo logs -l app.kubernetes.io/instance=defectdojo --tail=200
kubectl -n defectdojo get jobs
kubectl -n defectdojo describe job -l app.kubernetes.io/instance=defectdojo
```

Actions:
- Wait for initializer/migration jobs to complete.
- If needed, re-run Helm upgrade (idempotent) after fixing DB/PVC issues.
