#!/usr/bin/env bash
# Install the full monitoring stack: Prometheus + Grafana + Alertmanager + Loki + Fluent Bit + Elasticsearch + Kibana
set -euo pipefail

NAMESPACE=monitoring
SCRIPT_DIR="$(dirname "$0")"

# Add helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add elastic https://helm.elastic.co
helm repo update

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --values "$SCRIPT_DIR/kube-prometheus-stack-values.yaml" \
  --timeout 10m

echo ">>> Installing Loki..."
helm upgrade --install loki grafana/loki \
  --namespace "$NAMESPACE" \
  --values "$SCRIPT_DIR/loki-values.yaml" \
  --timeout 5m

echo ">>> Installing Elasticsearch..."
helm upgrade --install elasticsearch elastic/elasticsearch \
  --namespace "$NAMESPACE" \
  --version 8.5.1 \
  --values "$SCRIPT_DIR/elasticsearch-values.yaml" \
  --timeout 10m

echo ">>> Waiting for Elasticsearch to be ready..."
kubectl wait --for=condition=ready pod -l app=elasticsearch-master \
  -n "$NAMESPACE" --timeout=300s

echo ">>> Configuring Elasticsearch for single-node cluster..."
ES_POD=$(kubectl get pod -n "$NAMESPACE" -l app=elasticsearch-master -o jsonpath='{.items[0].metadata.name}')

# Index template: default to 0 replicas (single-node can't host replicas)
kubectl exec -n "$NAMESPACE" "$ES_POD" -- curl -s -X PUT \
  "http://localhost:9200/_index_template/single-node-defaults" \
  -H 'Content-Type: application/json' \
  -d '{"index_patterns":["*"],"priority":1,"template":{"settings":{"number_of_replicas":0}}}' \
  > /dev/null

# Create Kibana data view for k8s-logs indices (after Kibana is up below)

echo ">>> Creating dummy secrets for Kibana chart (security disabled on ES)..."
# The Kibana 8.5.1 chart requires these secrets to exist even when ES security is off
kubectl create secret generic elasticsearch-master-certs \
  --namespace "$NAMESPACE" \
  --from-literal=ca.crt="" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic kibana-kibana-es-token \
  --namespace "$NAMESPACE" \
  --from-literal=token="no-token-security-disabled" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">>> Installing Kibana (--no-hooks: pre-install hook requires HTTPS, security is disabled)..."
helm upgrade --install kibana elastic/kibana \
  --namespace "$NAMESPACE" \
  --version 8.5.1 \
  --values "$SCRIPT_DIR/kibana-values.yaml" \
  --no-hooks \
  --timeout 10m

echo ">>> Applying Kibana ingress..."
kubectl apply -f "$SCRIPT_DIR/kibana-ingress.yaml"

echo ">>> Installing Fluent Bit (dual output: Loki + Elasticsearch)..."
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace "$NAMESPACE" \
  --values "$SCRIPT_DIR/fluent-bit-values.yaml" \
  --timeout 5m

echo ">>> Waiting for Kibana to be ready..."
kubectl wait --for=condition=ready pod -l release=kibana \
  -n "$NAMESPACE" --timeout=300s

echo ">>> Creating Kibana data view for k8s-logs-*..."
KIBANA_POD=$(kubectl get pod -n "$NAMESPACE" -l release=kibana -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$KIBANA_POD" -- curl -s -X POST \
  "http://localhost:5601/api/data_views/data_view" \
  -H 'Content-Type: application/json' \
  -H 'kbn-xsrf: true' \
  -d '{"data_view":{"title":"k8s-logs-*","name":"Kubernetes Logs","timeFieldName":"@timestamp"}}' \
  > /dev/null && echo "    Data view created."

echo ""
echo ">>> Done."
echo "    Grafana:  https://grafana.immutablesoftware.dev (admin/admin — change on first login)"
echo "    Kibana:   https://kibana.immutablesoftware.dev"
