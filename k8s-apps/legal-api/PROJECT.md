# legal-api

**Namespace:** `legal-api`
**Purpose:** Legal API — backend service for the legal document processing platform.

## Secrets

| Secret Name | Sealed Source | Keys | Notes |
|-------------|--------------|------|-------|
| `legal-api-secrets` | `legal-api-secrets-sealed.yaml` | `ANTHROPIC_API_KEY`, `API_KEY`, `DATABASE_URL`, `GOVINFO_API_KEY`, `POSTGRES_PASSWORD`, `VOYAGE_AI_API_KEY` | App API keys and database credentials |

## Manifests

| File | Description |
|------|-------------|
| `legal-api-secrets-sealed.yaml` | SealedSecret — decrypted by sealed-secrets-controller in kube-system |

## Agent Access

Service account `agent` in namespace `legal-api` is bound to `ClusterRole/agent-secret-reader` via `RoleBinding/agent-secret-reader`.
To use from a pod: `serviceAccountName: agent`.

## Notes

- `DATABASE_URL` and `POSTGRES_PASSWORD` target the PostgreSQL instance shared with legal-ingestor
