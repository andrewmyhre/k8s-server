#!/usr/bin/env bash
set -euo pipefail

# Setup Cloudflare Tunnel for homelab-k8s
# Prerequisites: cloudflared login must have been completed (cert.pem exists)

KUBECONFIG="/home/andrew/admin.conf"
CLOUDFLARED="/usr/local/bin/cloudflared"
NAMESPACE="cloudflare-tunnel"
TUNNEL_NAME="homelab-k8s"
CF_TOKEN_FILE="/home/andrew/.claude/secrets/cloudflare"
ACCOUNT_ID="4a3e3b098c8eb54e718ca9f106544840"
ZONE_ID="33827e5f14a3620498a17e35bf9a2da4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify cert.pem exists
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
  echo "ERROR: cert.pem not found. Run 'cloudflared tunnel login' first."
  exit 1
fi

# Create the tunnel
echo "Creating tunnel: $TUNNEL_NAME"
$CLOUDFLARED tunnel create "$TUNNEL_NAME" 2>&1

# Get tunnel ID from credentials file
CREDS_FILE=$(ls "$HOME/.cloudflared/"*.json 2>/dev/null | head -1)
if [ -z "$CREDS_FILE" ]; then
  echo "ERROR: No tunnel credentials file found in ~/.cloudflared/"
  exit 1
fi

TUNNEL_ID=$(basename "$CREDS_FILE" .json)
echo "Tunnel ID: $TUNNEL_ID"

# Create k8s secret from credentials
echo "Creating k8s secret..."
kubectl --kubeconfig "$KUBECONFIG" -n "$NAMESPACE" create secret generic cloudflared-credentials \
  --from-file=credentials.json="$CREDS_FILE" \
  --dry-run=client -o yaml | kubectl --kubeconfig "$KUBECONFIG" apply -f -

# Create ConfigMap
echo "Creating ConfigMap..."
cat <<CFEOF | kubectl --kubeconfig "$KUBECONFIG" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: $NAMESPACE
data:
  config.yaml: |
    tunnel: $TUNNEL_ID
    credentials-file: /etc/cloudflared/creds/credentials.json
    ingress:
      - hostname: headlamp.primera.rodeo
        service: http://headlamp.headlamp.svc.cluster.local:4466
      - hostname: kubenav.primera.rodeo
        service: http://kubenav-skooner.kubenav.svc.cluster.local:14122
      - service: http_status:404
CFEOF

# Deploy cloudflared
echo "Deploying cloudflared..."
kubectl --kubeconfig "$KUBECONFIG" apply -f "$SCRIPT_DIR/cloudflared-deployment.yaml"

# Wait for pods
echo "Waiting for cloudflared pods..."
kubectl --kubeconfig "$KUBECONFIG" -n "$NAMESPACE" rollout status deployment/cloudflared --timeout=60s

# Create DNS records via cloudflared CLI
echo "Creating DNS routes..."
$CLOUDFLARED tunnel route dns "$TUNNEL_NAME" headlamp.primera.rodeo 2>&1 || true
$CLOUDFLARED tunnel route dns "$TUNNEL_NAME" kubenav.primera.rodeo 2>&1 || true

echo ""
echo "Tunnel setup complete!"
echo "Tunnel ID: $TUNNEL_ID"
echo "Headlamp: https://headlamp.primera.rodeo"
echo "Kubenav/Skooner: https://kubenav.primera.rodeo"
