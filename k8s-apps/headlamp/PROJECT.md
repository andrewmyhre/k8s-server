# headlamp

**Namespace:** `headlamp`
**Purpose:** Headlamp — Kubernetes UI dashboard.

## Secrets

| Secret Name | Sealed Source | Keys | Notes |
|-------------|--------------|------|-------|
| `headlamp-kubeconfig` | `headlamp-kubeconfig-sealed.yaml` | `config` | Kubeconfig granting cluster-admin access for the Headlamp UI |

## Manifests

| File | Description |
|------|-------------|
| `headlamp-values.yaml` | Helm values for `headlamp/headlamp` chart |
| `headlamp-kubeconfig-sealed.yaml` | SealedSecret — decrypted by sealed-secrets-controller in kube-system |

## Agent Access

Service account `agent` in namespace `headlamp` is bound to `ClusterRole/agent-secret-reader` via `RoleBinding/agent-secret-reader`.
To use from a pod: `serviceAccountName: agent`.

## Notes

- The `headlamp-kubeconfig` secret contains a **cluster-admin kubeconfig** — treat as highly sensitive.
- URL: https://headlamp.immutablesoftware.dev (auth via Cloudflare Access)
