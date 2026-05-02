#!/usr/bin/env bash
# seal-credentials.sh — create a SealedSecret holding the us-egress-proxy
# credentials for a given namespace.
#
# Usage:
#     PROXY_PASSWORD='...' ./seal-credentials.sh <namespace>
#
# The resulting SealedSecret is written to
#   us-egress-proxy-creds-<namespace>-sealed.yaml
# and should be committed to the repo (it is safe to commit — the payload is
# encrypted to the cluster's sealed-secrets controller public key).
#
# The plaintext Secret (once unsealed by the controller) will contain:
#   HTTPS_PROXY = http://proxyuser:<password>@192.168.0.10:8888
#   HTTP_PROXY  = http://proxyuser:<password>@192.168.0.10:8888
# so workloads can mount it with envFrom and respect the standard proxy env.

set -euo pipefail

NS="${1:-}"
[[ -n "$NS" ]]                    || { echo "usage: PROXY_PASSWORD=... $0 <namespace>" >&2; exit 1; }
[[ -n "${PROXY_PASSWORD:-}" ]]    || { echo "ERROR: PROXY_PASSWORD env var must be set"       >&2; exit 1; }
command -v kubeseal >/dev/null    || { echo "ERROR: kubeseal not installed"                  >&2; exit 1; }
command -v kubectl  >/dev/null    || { echo "ERROR: kubectl not installed"                   >&2; exit 1; }

PROXY_URL="http://proxyuser:${PROXY_PASSWORD}@192.168.0.10:8888"
NAME="us-egress-proxy-creds"
OUT="us-egress-proxy-creds-${NS}-sealed.yaml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Sealing $NAME into namespace $NS -> $OUT"

kubectl create secret generic "$NAME" \
    --namespace="$NS" \
    --from-literal=HTTPS_PROXY="$PROXY_URL" \
    --from-literal=HTTP_PROXY="$PROXY_URL" \
    --dry-run=client -o yaml \
  | kubeseal --format=yaml > "$OUT"

echo "Wrote $OUT"
echo
echo "Apply with:"
echo "    kubectl apply -f $OUT"
echo
echo "Reference from a Deployment:"
echo "    envFrom:"
echo "      - secretRef:"
echo "          name: $NAME"
echo "    env:"
echo "      - name: NO_PROXY"
echo "        value: .cluster.local,.svc,10.0.0.0/8,192.168.0.0/16"
