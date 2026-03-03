# k8s-server

Kubernetes infrastructure manifests and helm values for the homelab cluster (`sleeper-service`, 192.168.0.10).

Common infrastructure shared across all applications — not tied to any single project.

## Cluster

- **Node**: sleeper-service (192.168.0.10), Ubuntu 24.04, k8s v1.35.2, 12 CPU / 58GB RAM
- **Storage**: local-path (default StorageClass, rancher.io/local-path)
- **Ingress**: ingress-nginx on NodePort 30080/30443
- **External access**: Cloudflare Tunnel (tunnel ID: 6c51f837-c566-45d2-b0ab-669f416ffbc4)

## Installed Components

| Component | Namespace | Helm Chart | URL |
|-----------|-----------|------------|-----|
| Prometheus | monitoring | prometheus-community/kube-prometheus-stack | internal |
| Grafana | monitoring | (included in kube-prometheus-stack) | https://grafana.immutablesoftware.dev |
| Alertmanager | monitoring | (included in kube-prometheus-stack) | internal |
| Loki | monitoring | grafana/loki | internal:3100 |
| Fluent Bit | monitoring | fluent/fluent-bit | DaemonSet |
| Argo Workflows | argo | argo/argo-workflows | https://argo-workflows.immutablesoftware.dev |
| ingress-nginx | ingress-nginx | kubernetes/ingress-nginx | NodePort 30080/30443 |
| local-path-provisioner | local-path-storage | rancher/local-path-provisioner | default StorageClass |

## Directory Structure

```
monitoring/
  install.sh                        # One-shot install script
  kube-prometheus-stack-values.yaml # Prometheus + Grafana + Alertmanager
  loki-values.yaml                  # Loki (single-binary mode)
  fluent-bit-values.yaml            # Log shipping to Loki

argo/
  ingress.yaml                      # nginx Ingress for Argo Workflows UI
```

## Setup

### Prerequisites

```bash
# Add helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install local-path-provisioner (if not present)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
```

### Install Monitoring Stack

```bash
cd monitoring
./install.sh
```

### Install Argo Workflows

```bash
helm install argo-workflows argo/argo-workflows -n argo --create-namespace \
  --set server.extraArgs="{--auth-mode=server}" \
  --set workflow.serviceAccount.create=true
kubectl apply -f argo/ingress.yaml
```

## Grafana

- URL: https://grafana.immutablesoftware.dev
- Default credentials: `admin` / `admin` (change on first login)
- Loki datasource pre-configured
- Prometheus datasource pre-configured (by kube-prometheus-stack)
