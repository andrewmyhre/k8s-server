# legal-ingestor

**Namespace:** `legal-ingestor`
**Purpose:** Legal API Ingestor — Argo Workflow that periodically ingests legal documents from govinfo.gov into S3 and the legal-api database.

## Secrets

| Secret Name | Sealed Source | Keys | Notes |
|-------------|--------------|------|-------|
| `ingestor-secrets` | `ingestor-secrets-sealed.yaml` | `ADMIN_API_URL`, `ANTHROPIC_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_REGION`, `AWS_SECRET_ACCESS_KEY`, `DOCUMENTS_BUCKET`, `GOVINFO_API_KEY`, `INGESTOR_SECRET`, `VOYAGE_AI_API_KEY` | AWS S3, API keys, ingestor auth token |

## Manifests

| File | Description |
|------|-------------|
| `ingestor-secrets-sealed.yaml` | SealedSecret — decrypted by sealed-secrets-controller in kube-system |

## Agent Access

Service account `agent` in namespace `legal-ingestor` is bound to `ClusterRole/agent-secret-reader` via `RoleBinding/agent-secret-reader`.
To use from a pod: `serviceAccountName: agent`.

## Known Issues

- **Memory Leak (CRITICAL):** The ingestor Argo Workflow pod has a severe memory leak; OOM-killed repeatedly.
  Caused a system crash on 2026-03-07. Fix: add `resources.limits.memory: 8Gi` to the Workflow pod spec.
- CronWorkflow `legal-api/legal-api-ingestor-weekly` retries automatically on failure.
