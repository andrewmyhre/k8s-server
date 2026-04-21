# Helm Deployments

How Helm charts are deployed, upgraded, and managed in the homelab cluster.

---

## Overview

All infrastructure and most applications are deployed via Helm. The cluster uses `helm upgrade --install` as the standard deployment pattern — idempotent, works for both initial install and subsequent upgrades.

**Helm binary:** `/home/linuxbrew/.linuxbrew/Cellar/helm/4.1.1/bin/helm`

## Required Helm Repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add elastic https://helm.elastic.co
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
```

## Deployed Releases

| Release | Namespace | Chart | Version | Values File |
|---------|-----------|-------|---------|-------------|
| **Infrastructure** |
| cilium | default | cilium/cilium | 1.19.1 | `infra/cilium/values-sleeper-service.yaml` |
| ingress-nginx | ingress-nginx | ingress-nginx/ingress-nginx | 4.14.3 | — |
| sealed-secrets | kube-system | sealed-secrets/sealed-secrets | 2.18.4 | `k8s-apps/sealed-secrets-values.yaml` |
| metrics-server | kube-system | metrics-server/metrics-server | 3.13.0 | `monitoring/metrics-server-values.yaml` |
| **Monitoring** |
| kube-prometheus-stack | monitoring | prometheus-community/kube-prometheus-stack | 82.10.4 | `monitoring/kube-prometheus-stack-values.yaml` |
| loki | monitoring | grafana/loki | 6.53.0 | `monitoring/loki-values.yaml` |
| fluent-bit | monitoring | fluent/fluent-bit | 0.56.0 | `monitoring/fluent-bit-values.yaml` |
| elasticsearch | monitoring | elastic/elasticsearch | 8.5.1 | — |
| kibana | monitoring | elastic/kibana | 8.5.1 | — |
| prometheus-pushgateway | monitoring | prometheus-community/prometheus-pushgateway | 3.6.0 | — |
| **CI/CD** |
| argo-workflows | argo | argo/argo-workflows | 0.47.4 | `argo/argo-workflows-values.yaml` |
| **Applications** |
| huddle | huddle | huddle/huddle | 0.1.0 | (app chart) |
| huddle-test | huddle-test | huddle/huddle | 0.1.0 | (app chart) |
| scribi | scribi | scribi/scribi | 0.1.0 | (app chart) |
| scribi-test | scribi-test | scribi/scribi | 0.1.0 | (app chart) |
| legal-api | legal-api | legal-api/legal-api | 0.1.0 | (app chart) |
| kubenav | kubenav | kubenav/skooner | 0.3.1 | `k8s-apps/kubenav-values.yaml` |
| **Media** (app-template) |
| plex | media | app-template | 4.6.2 | — |
| radarr | media | app-template | 4.6.2 | — |
| sonarr | media | app-template | 4.6.2 | — |
| lidarr | media | app-template | 4.6.2 | — |
| bazarr | media | app-template | 4.6.2 | — |
| prowlarr | media | app-template | 4.6.2 | — |
| qbittorrent | media | app-template | 4.6.2 | — |
| sabnzbd | media | app-template | 4.6.2 | — |
| flaresolverr | media | app-template | 4.6.2 | — |

## Values Files

Custom Helm values are stored in the repo alongside the manifests they configure:

```
monitoring/
  kube-prometheus-stack-values.yaml    # Grafana, Prometheus, Alertmanager
  loki-values.yaml                     # Loki single-binary mode
  fluent-bit-values.yaml               # Fluent Bit DaemonSet
  metrics-server-values.yaml           # metrics-server (hostNetwork workaround)

argo/
  argo-workflows-values.yaml           # Argo server auth, controller namespaces, TTL

infra/
  cilium/values-sleeper-service.yaml   # Cilium CNI (apiserver host IP fix)

k8s-apps/
  sealed-secrets-values.yaml           # Sealed Secrets controller
  headlamp-values.yaml                 # Headlamp dashboard
  kubenav-values.yaml                  # KubeNav/Skooner dashboard
```

Every values file includes install/upgrade commands in its header comments.

## Deployment Patterns

### Standard Install/Upgrade

```bash
helm upgrade --install <release> <chart> \
  --namespace <namespace> --create-namespace \
  --values <values-file> \
  --timeout 10m
```

### Monitoring Stack (Scripted)

The full monitoring stack has a scripted installer at `monitoring/install.sh`:

```bash
./monitoring/install.sh
```

This installs kube-prometheus-stack, Loki, and Fluent Bit in sequence with their respective values files.

### Kibana (Special Case)

Kibana requires `--no-hooks` because the pre-install hook is hardcoded to HTTPS, which breaks when Elasticsearch security is disabled:

```bash
helm upgrade --install kibana elastic/kibana \
  --namespace monitoring \
  --no-hooks
```

## Known Issues

### kube-prometheus-stack Upgrades Hang

Upgrades hang because ~35 PrometheusRules each trigger the validation webhook on port 10250 (same as kubelet). Resources ARE applied before the hang — the upgrade is effectively complete.

**Recovery:**
1. Confirm pods are healthy: `kubectl get pods -n monitoring`
2. Find the latest release secret:
   ```bash
   kubectl get secrets -n monitoring | grep sh.helm.release.v1.kube-prometheus-stack
   ```
3. Decode the secret (base64 × 2 + gunzip), change `info.status` to `"deployed"`, re-encode, and patch:
   ```bash
   kubectl patch secret <secret-name> -n monitoring -p '{"data":{"release":"<re-encoded>"}}'
   ```

### Grafana Chart v11 Volume Quirk

The Grafana chart's `extraVolumes` silently ignores secret-type volumes — it only handles `existingClaim`, `hostPath`, `csi`, `configMap`, and `emptyDir`. Use `extraContainerVolumes` instead for secret volumes.

### Grafana envFromSecret

The chart key is `envFromSecret` (a single string), **not** `envFrom: [{secretRef: {name: ...}}]`:

```yaml
grafana:
  envFromSecret: grafana-alerting-credentials   # Correct
```

## Ingress Convention

All ingresses use:
- `ingressClassName: nginx`
- Hostnames under `*.immutablesoftware.dev` (infrastructure) or `*.primera.rodeo` (media apps)
- Cloudflare Access provides perimeter authentication — no in-cluster auth needed for protected services
