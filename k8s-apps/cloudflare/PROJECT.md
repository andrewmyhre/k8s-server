# cloudflare

**Namespace:** `cloudflare`
**Purpose:** Cloudflare Tunnel daemon (cloudflared) — routes ingress traffic from Cloudflare's network to in-cluster services.

## Secrets

| Secret Name | Sealed Source | Keys | Notes |
|-------------|--------------|------|-------|
| `cloudflared-token` | `cloudflared-token-sealed.yaml` | `token` | Cloudflare Tunnel token; rotate at https://one.dash.cloudflare.com |

## Manifests

| File | Description |
|------|-------------|
| `cloudflared-deployment.yaml` | Cloudflared tunnel deployment (2 replicas) |
| `cloudflared-token-sealed.yaml` | SealedSecret — decrypted by sealed-secrets-controller in kube-system |

## Agent Access

Service account `agent` in namespace `cloudflare` is bound to `ClusterRole/agent-secret-reader` via `RoleBinding/agent-secret-reader`.
To use from a pod: `serviceAccountName: agent`.

## Notes

- Tunnel token was previously stored as plaintext at `secrets/cloudflare` (deleted after sealing)
- `cloudflared` reads the token from `TUNNEL_TOKEN` env var sourced from the secret
