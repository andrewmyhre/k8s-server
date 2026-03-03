# k8s-server

Kubernetes infrastructure manifests and Helm values for the homelab cluster (`sleeper-service`, 192.168.0.10).

This repo is the source of truth for all common cluster infrastructure — monitoring, ingress, storage, CI/CD orchestration, and shared services that span multiple applications.

## Cluster

| Property | Value |
|----------|-------|
| Node | sleeper-service (192.168.0.10) |
| k8s version | v1.35.2 |
| Container runtime | containerd 2.2.1 |
| OS | Ubuntu 24.04.4 LTS |
| StorageClass | local-path (rancher.io/local-path) |
| Ingress | nginx (NodePort 30080/30443) |
| External access | Cloudflare Tunnel (6c51f837-c566-45d2-b0ab-669f416ffbc4) |

## Directory Structure

```
monitoring/     Prometheus, Grafana, Loki, Fluent Bit
argo/           Argo Workflows ingress and config
```

## Helm Repos Required

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```
