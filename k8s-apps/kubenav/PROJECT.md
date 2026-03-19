# kubenav

**Namespace:** `kubenav`
**Purpose:** KubeNav — mobile/desktop Kubernetes navigator app.

## Secrets

| Secret Name | Sealed Source | Keys | Notes |
|-------------|--------------|------|-------|
| `dashboard-admin-token` | `dashboard-admin-token-sealed.yaml` | `token` | Bearer token for cluster-admin service account used by KubeNav |

## Manifests

| File | Description |
|------|-------------|
| `kubenav-values.yaml` | Helm values for `kubenav/kubenav` chart |
| `dashboard-admin-token-sealed.yaml` | SealedSecret — decrypted by sealed-secrets-controller in kube-system |

## Agent Access

Service account `agent` in namespace `kubenav` is bound to `ClusterRole/agent-secret-reader` via `RoleBinding/agent-secret-reader`.
To use from a pod: `serviceAccountName: agent`.

## Notes

- The `dashboard-admin-token` contains a **cluster-admin bearer token** — treat as highly sensitive.
