#!/usr/bin/env bash
# Install the full monitoring stack: Prometheus + Grafana + Alertmanager + Loki + Fluent Bit
set -euo pipefail

NAMESPACE=monitoring

# Add helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --values "$(dirname "$0")/kube-prometheus-stack-values.yaml" \
  --timeout 10m

echo ">>> Installing Loki..."
helm upgrade --install loki grafana/loki \
  --namespace "$NAMESPACE" \
  --values "$(dirname "$0")/loki-values.yaml" \
  --timeout 5m

echo ">>> Installing Fluent Bit..."
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace "$NAMESPACE" \
  --values "$(dirname "$0")/fluent-bit-values.yaml" \
  --timeout 5m

echo ">>> Done. Grafana: https://grafana.immutablesoftware.dev (admin/admin — change on first login)"
