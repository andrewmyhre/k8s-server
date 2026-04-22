#!/usr/bin/env bash
# install.sh — install us-egress-proxy on sleeper-service.
#
# What this does:
#   1. Installs tinyproxy + nftables (apt).
#   2. Drops the nftables bypass rule and systemd unit into place.
#   3. Generates a strong random proxy password (or uses $PROXY_PASSWORD if set).
#   4. Writes /etc/tinyproxy/tinyproxy.conf with that password substituted.
#   5. Enables + starts both services (bypass first, then tinyproxy).
#   6. Verifies end-to-end: socket listening, DNS works from tinyproxy UID,
#      and a proxied curl reaches the internet via ISP (not Mullvad).
#   7. Prints the generated password so it can be sealed into k8s.
#
# Run on sleeper-service as root (or via sudo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="$SCRIPT_DIR/tinyproxy.conf"
NFT_SRC="$SCRIPT_DIR/us-egress-proxy-bypass.nft"
SVC_SRC="$SCRIPT_DIR/us-egress-proxy-bypass.service"

CONF_DST="/etc/tinyproxy/tinyproxy.conf"
NFT_DST="/etc/nftables.d/us-egress-proxy-bypass.nft"
SVC_DST="/etc/systemd/system/us-egress-proxy-bypass.service"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root (try: sudo $0)"
[[ $(hostname) == "sleeper-service" ]] || die "Run this on sleeper-service, not $(hostname)"

log "Installing tinyproxy + nftables"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tinyproxy nftables dnsutils curl

log "Ensuring /etc/nftables.d is included from /etc/nftables.conf"
mkdir -p /etc/nftables.d
if ! grep -q 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf 2>/dev/null; then
    echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
fi

log "Installing nftables bypass rule: $NFT_DST"
install -m 0644 "$NFT_SRC" "$NFT_DST"

log "Installing systemd unit: $SVC_DST"
install -m 0644 "$SVC_SRC" "$SVC_DST"

log "Generating proxy credentials"
if [[ -n "${PROXY_PASSWORD:-}" ]]; then
    password="$PROXY_PASSWORD"
    echo "Using PROXY_PASSWORD from environment."
else
    # Strip /+= from base64 output — keeps password URL-safe and sed-safe.
    password=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    echo "Generated new random password (32 chars, alnum)."
fi

log "Writing $CONF_DST"
# Password is alnum-only by construction, so no regex escaping needed — but
# use an uncommon sed delimiter to be safe.
sed -e "s|PLACEHOLDER_PASSWORD|$password|" "$CONF_SRC" > "$CONF_DST"
chown root:tinyproxy "$CONF_DST"
chmod 0640 "$CONF_DST"

log "Enabling + starting services (bypass first, then tinyproxy)"
systemctl daemon-reload
systemctl enable --now us-egress-proxy-bypass.service
systemctl restart tinyproxy.service
systemctl enable tinyproxy.service

# ─── Verification ──────────────────────────────────────────────────────────
# Each check gives a distinct error so a failure tells you exactly where to
# look, rather than collapsing to a single "CURL_FAILED".

log "Verifying nft rule is loaded and resolves tinyproxy UID"
if ! nft list table inet us-egress-proxy >/dev/null 2>&1; then
    die "nft table inet us-egress-proxy is not loaded. Check: systemctl status us-egress-proxy-bypass"
fi
nft list table inet us-egress-proxy

log "Verifying tinyproxy is listening on 192.168.0.10:8888"
sleep 1
if ! ss -tln | awk '{print $4}' | grep -qx '192.168.0.10:8888'; then
    ss -tln | grep 8888 || true
    die "tinyproxy is not listening on 192.168.0.10:8888. Check: systemctl status tinyproxy"
fi

log "Verifying DNS works from the tinyproxy UID"
# With the mole marks, tinyproxy's DNS queries MUST go through the tunnel to
# reach 10.64.0.1 — our nft rule excludes port 53 from the marks. If DNS
# fails here, the exclusion rule is misconfigured.
if ! sudo -u tinyproxy dig am.i.mullvad.net +time=3 +tries=1 +short >/dev/null 2>&1; then
    die "DNS resolution from the tinyproxy UID failed. The nft rule should exempt port 53 — check $NFT_DST."
fi

log "Verifying proxy egress goes via ISP, not Mullvad"
set +e
proxy_response=$(curl -sS --max-time 15 \
    -x "http://proxyuser:${password}@192.168.0.10:8888" \
    https://am.i.mullvad.net/connected 2>&1)
curl_exit=$?
set -e

if [[ $curl_exit -ne 0 ]]; then
    echo "curl exit code: $curl_exit"
    echo "curl output:    $proxy_response"
    die "curl via proxy failed. If exit=7 the socket is unreachable; if exit=28 the upstream is timing out (likely Mullvad filter); if exit=56 the proxy returned an error. Check /var/log/tinyproxy/tinyproxy.log."
fi

echo "am.i.mullvad.net says: $proxy_response"
if [[ "$proxy_response" == *"You are connected to Mullvad"* ]]; then
    die "Proxy is STILL routing through Mullvad. Check nft rule + systemd ordering."
fi

log "SUCCESS — proxy egress is bypassing Mullvad."

cat <<EOF

================================================================================
  us-egress-proxy installed.

  Endpoint:  http://192.168.0.10:8888
  Username:  proxyuser
  Password:  $password

  NEXT STEPS
  ----------
  1. Seal this password for each namespace that needs it:

         cd /projects/homelab/us-egress-proxy/k8s
         PROXY_PASSWORD='$password' ./seal-credentials.sh <namespace>

  2. Reference the SealedSecret in the consuming Deployment. See
     example-consumer.yaml for the pattern.

  3. Delete any local plaintext copy of this password. It now lives only
     in /etc/tinyproxy/tinyproxy.conf (root:tinyproxy 0640) on this host
     and in SealedSecrets in the cluster.
================================================================================
EOF
