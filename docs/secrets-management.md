# Secrets Management

How secrets are encrypted, stored, and consumed in the homelab Kubernetes cluster.

---

## Architecture: Bitnami Sealed Secrets

All secrets are managed via [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets). The controller runs in `kube-system` and decrypts `SealedSecret` resources into standard Kubernetes `Secret` objects at runtime.

| Property | Value |
|----------|-------|
| Chart | `sealed-secrets/sealed-secrets` v2.18.4 |
| Controller release | `sealed-secrets` (namespace: `kube-system`) |
| Controller image | `bitnami/sealed-secrets-controller:0.36.1` |
| CLI | `/usr/local/bin/kubeseal` |
| Values file | `k8s-apps/sealed-secrets-values.yaml` |

## How It Works

```
┌──────────────┐     kubeseal      ┌──────────────────┐     controller     ┌──────────────┐
│ Plain Secret │  ───────────────► │  SealedSecret    │  ────────────────► │ K8s Secret   │
│ (never in    │   (encrypts with  │  (safe to commit │   (decrypts in-   │ (lives only  │
│  git)        │    controller's   │   to git)        │    cluster)       │  in etcd)    │
└──────────────┘    public key)    └──────────────────┘                   └──────────────┘
```

1. **Author** creates a plain `Secret` manifest locally (or pipes from stdin)
2. **`kubeseal`** encrypts it using the controller's public certificate — output is a `SealedSecret` YAML
3. **SealedSecret** is committed to git (encrypted, safe to store in version control)
4. **Controller** watches for `SealedSecret` resources, decrypts them, and creates the corresponding `Secret` in the target namespace
5. **Pods** consume the `Secret` via `envFrom`, `env[].valueFrom.secretKeyRef`, or volume mounts

## Sealing a Secret

```bash
# From a file
kubeseal --format yaml < secret.yaml > sealed-secret.yaml

# From stdin (one-liner for a single key)
kubectl create secret generic my-secret \
  --namespace my-ns \
  --from-literal=API_KEY=sk-xxx \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > my-secret-sealed.yaml

# Apply to cluster
kubectl apply -f my-secret-sealed.yaml
```

The `kubeseal` CLI auto-discovers the controller in `kube-system` (because the release is named `sealed-secrets-controller`).

## File Naming Convention

All sealed secret files follow the pattern:

```
k8s-apps/<namespace>/<name>-sealed.yaml
```

For monitoring-specific secrets:
```
monitoring/<name>-sealed.yaml
```

## Secrets Inventory

| Namespace | Secret Name | Sealed File | Keys |
|-----------|-------------|-------------|------|
| ai-services | `aws-deploy-credentials` | — | AWS deploy creds |
| ai-services | `cloudflare-api-token` | — | CF API token |
| ai-services | `deploy-env-preview` | — | Preview env vars |
| ai-services | `deploy-env-production` | — | Production env vars |
| ai-services | `github-token` | — | GitHub token |
| ai-services | `stripe-prod` | — | Stripe production keys |
| ai-services | `stripe-sandbox` | — | Stripe sandbox keys |
| cloudflare | `cloudflared-token` | `k8s-apps/cloudflare/cloudflared-token-sealed.yaml` | `token` |
| headlamp | `headlamp-kubeconfig` | `k8s-apps/headlamp/headlamp-kubeconfig-sealed.yaml` | `config` |
| huddle | `huddle-api-secrets` | `k8s-apps/huddle/huddle-api-secrets-sealed.yaml` | `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` |
| kubenav | `dashboard-admin-token` | `k8s-apps/kubenav/dashboard-admin-token-sealed.yaml` | `token` |
| legal-api | `legal-api-secrets` | `k8s-apps/legal-api/legal-api-secrets-sealed.yaml` | `ANTHROPIC_API_KEY`, `API_KEY`, `DATABASE_URL`, `GOVINFO_API_KEY`, `POSTGRES_PASSWORD`, `VOYAGE_AI_API_KEY` |
| legal-ingestor | `ingestor-secrets` | `k8s-apps/legal-ingestor/ingestor-secrets-sealed.yaml` | `ADMIN_API_URL`, `ANTHROPIC_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_REGION`, `AWS_SECRET_ACCESS_KEY`, `DOCUMENTS_BUCKET`, `GOVINFO_API_KEY`, `INGESTOR_SECRET`, `VOYAGE_AI_API_KEY` |
| legal-ingestor | `cloudflare-credentials` | — | CF credentials |
| monitoring | `grafana-alerting-credentials` | `k8s-apps/monitoring/grafana-alerting-sealed.yaml` | `GF_SMTP_USER`, `GF_SMTP_PASSWORD`, `GF_SLACK_TOKEN` |
| monitoring | `grafana-alerting-provisioning` | `k8s-apps/monitoring/grafana-alerting-provisioning-sealed.yaml` | Full alerting provisioning YAML (Slack token embedded) |
| monitoring | `grafana-influxdb-creds` | `monitoring/grafana-influxdb-creds-sealed.yaml` | InfluxDB credentials |
| monitoring | `grafana-influxdb-datasource` | `monitoring/grafana-influxdb-datasource-sealed.yaml` | Datasource provisioning YAML (password embedded) |
| monitoring | `additional-scrape-configs` | `monitoring/home-assistant-scrape-config-sealed.yaml` | Prometheus scrape configs |
| pai | `pai-aws-credentials` | — | AWS credentials |
| pai | `pai-claude-api-key` | `k8s-apps/pai-claude-api-key-sealed.yaml` | Claude API key |
| pai | `pai-resend-api-key` | — | Resend API key |
| pai | `pai-serpapi-key` | `k8s-apps/pai-serpapi-key-sealed.yaml` | SerpAPI key |
| yaisa-job-search | `job-search-secrets` | — | Job search service secrets |

## RBAC: Agent Secret Access

A `ClusterRole` named `agent-secret-reader` grants `get` and `list` on secrets. It is bound per-namespace via `RoleBinding` (not `ClusterRoleBinding`), so access is always scoped to a single namespace.

**Manifest:** `k8s-apps/rbac/agent-secret-reader.yaml`

**Pattern:** One `ClusterRole` (reusable) + per-namespace `ServiceAccount/agent` + `RoleBinding`.

Namespaces with agent secret access:
- cloudflare
- huddle
- legal-api
- legal-ingestor
- headlamp
- kubenav

Pods authenticate as `serviceAccountName: agent` in their namespace and can only read secrets within that namespace — no cross-namespace access.

## Grafana Secrets: Init Container Pattern

Grafana 12 does **not** support environment variable substitution (`$__env{VAR}`) in alerting contact point settings. The token validation fires at YAML parse time. This requires embedding secrets directly in provisioning YAML files.

**Solution:** SealedSecret → init container → emptyDir → Grafana reads at startup.

```
SealedSecret (encrypted full YAML)
    │
    ▼
Init Container (busybox:1.36)
    │  cp /src/*.yaml /dest/
    ▼
emptyDir volume
    │
    ▼
Grafana container reads /etc/grafana/provisioning/alerting/
```

The same pattern is used for the InfluxDB datasource provisioning (password embedded in YAML).

See `monitoring/kube-prometheus-stack-values.yaml` for the full implementation.

## Plaintext Secrets

The `secrets/` directory at the repo root is **gitignored** and holds plaintext credential files used for local reference only. These are never committed.

```
# .gitignore
secrets/
```

## Critical Warning: Controller Key Pair

If the sealed-secrets controller is destroyed and recreated, **all existing SealedSecrets become unreadable** because the encryption key pair changes.

**Back up the key pair:**
```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-backup.yaml
```

Store this backup securely outside the cluster. Without it, every SealedSecret must be re-sealed after a controller reinstall.
