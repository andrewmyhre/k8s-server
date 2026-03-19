# huddle

**Namespace:** `huddle`
**Purpose:** Huddle — PAI collaborative session system.

## Secrets

| Secret Name | Sealed Source | Keys | Notes |
|-------------|--------------|------|-------|
| `huddle-api-secrets` | `huddle-api-secrets-sealed.yaml` | `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` | API keys and Web Push VAPID credentials |

## Manifests

| File | Description |
|------|-------------|
| `huddle-api-secrets-sealed.yaml` | SealedSecret — decrypted by sealed-secrets-controller in kube-system |

## Agent Access

Service account `agent` in namespace `huddle` is bound to `ClusterRole/agent-secret-reader` via `RoleBinding/agent-secret-reader`.
To use from a pod: `serviceAccountName: agent`.
