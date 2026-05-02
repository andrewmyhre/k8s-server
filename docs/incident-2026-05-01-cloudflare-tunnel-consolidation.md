# Incident Report: Cloudflare Tunnel Consolidation

**Date:** 2026-05-01
**Duration:** ~30 minutes
**Severity:** Medium (tunnel degraded, then down during migration)
**Status:** Resolved

## Summary

Two separate Cloudflare tunnels were discovered running in parallel: one on the host (`public`, ID `6c51f837`) and one in Kubernetes (`homelab-k8s`, ID `68e03795`). The host tunnel was degraded (1/4 connections), the k8s tunnel was completely down (0 connections despite 2 running pods). A hostname conflict existed for `huddle.primera.rodeo` which was configured in both tunnels.

All routes were consolidated to the host tunnel, the k8s tunnel was deleted, and a root cause was found for the tunnel's inability to restart: Cloudflare rejects tunnel registration from Mullvad VPN exit IPs.

## Root Cause

### Degraded/Down Tunnel
The host tunnel was running through Mullvad VPN (exit IP in Stockholm). Cloudflare's edge was intermittently rejecting QUIC connections from the VPN IP, leaving only 1 of 4 connections alive. After a restart, Cloudflare rejected ALL registration attempts (both QUIC and HTTP/2 fallback), making the tunnel completely unrecoverable until a Mullvad bypass was added.

### Dual Tunnel
The k8s tunnel (`homelab-k8s`) appeared to be created as an experiment to route traffic directly to k8s services (bypassing nginx ingress). It was using a token-based auth (remotely managed) while the host tunnel used credentials-file auth. The k8s tunnel had 0 active connections despite healthy pods, suggesting it was also affected by the Mullvad issue or had stale credentials.

## Changes Made

### 1. Route Migration (Cloudflare API)
Added 5 routes to the host tunnel (`6c51f837`) that previously existed only in the k8s tunnel:

| Hostname | Zone |
|----------|------|
| `legal-api.immutablesoftware.dev` | immutablesoftware.dev |
| `huddle-dev.primera.rodeo` | primera.rodeo |
| `headlamp.primera.rodeo` | primera.rodeo |
| `kubenav.primera.rodeo` | primera.rodeo |
| `woodpecker.primera.rodeo` | primera.rodeo |

`huddle.primera.rodeo` was already in the host tunnel (conflict resolved by removing k8s tunnel).

### 2. DNS CNAME Updates (Cloudflare API)
Repointed 5 DNS CNAME records from `68e03795...cfargotunnel.com` to `6c51f837...cfargotunnel.com`:
- `legal-api.immutablesoftware.dev`
- `headlamp.primera.rodeo`
- `huddle-dev.primera.rodeo`
- `kubenav.primera.rodeo`
- `woodpecker.primera.rodeo`

### 3. Kubernetes Ingress Objects Created
Created nginx Ingress resources for services that previously bypassed ingress via the k8s tunnel's direct-to-service routing:
- `legal-api` Ingress in `legal-api` namespace (host: `legal-api.immutablesoftware.dev`, backend: `legal-api:8080`)
- `woodpecker` Ingress in `woodpecker` namespace (host: `woodpecker.primera.rodeo`, backend: `woodpecker-server:80`)

Existing Ingresses already covered: `huddle`, `huddle-dev`, `headlamp`, `kubenav`.

### 4. K8s Tunnel Cleanup
- Cleared all routes from k8s tunnel via API
- Deleted tunnel `68e03795-e772-48c1-b9aa-5e62016197af` via Cloudflare API
- Deleted `cloudflared` Deployment, `cloudflared-token` Secret, and `cloudflare` Namespace from the cluster
- Removed `k8s-apps/cloudflare/` directory from the homelab repo (deployment yaml, sealed token, PROJECT.md)

### 5. Mullvad VPN Bypass for cloudflared
Added nftables rules to bypass Mullvad for cloudflared's tunnel traffic on port 7844 (QUIC + HTTP/2):

```nft
tcp dport 7844 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
udp dport 7844 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
```

Updated in:
- `us-egress-proxy/host/us-egress-proxy-bypass.nft` (repo)
- `/etc/nftables.d/us-egress-proxy-bypass.nft` (deployed)

### 6. Host Service Cleanup
- Removed `Requires=qbittorrent-nox sabnzbd sonarr radarr prowlarr` from `/etc/systemd/system/cloudflared.service` (all services have moved to k8s `media` namespace)
- Removed `After=...` dependencies on the same services
- Stopped, disabled, and deleted `sabnzbdplus` init script (service confirmed running in k8s as `sabnzbd-697b4f7c6-xl89k` in `media` namespace for 45 days)

### 7. cloudflared Restart
Restarted cloudflared service. Result: **healthy** with 4/4 QUIC connections to Cloudflare edge (ewr01, ewr13, ewr15), origin IP `74.105.56.140` (ISP, not Mullvad).

## Verification

| Check | Result |
|-------|--------|
| Host tunnel status | healthy, 4/4 connections |
| K8s tunnel | Deleted at 2026-05-01T12:08:27Z |
| `cloudflare` namespace | NotFound (deleted) |
| `sabnzbdplus` service | inactive (stopped + disabled) |
| `legal-api.immutablesoftware.dev` | 404 (API, expected) |
| `huddle-dev.primera.rodeo` | 302 (Access redirect, expected) |
| `headlamp.primera.rodeo` | 302 (Access redirect, expected) |
| `kubenav.primera.rodeo` | 302 (Access redirect, expected) |
| `woodpecker.primera.rodeo` | 302 (Access redirect, expected) |
| `huddle.primera.rodeo` | 200 |
| `grafana.immutablesoftware.dev` | 302 (Access redirect, expected) |

## Lessons Learned

1. **Cloudflare rejects tunnel registration from VPN exit IPs.** Any service that needs to register with Cloudflare must bypass the VPN. This was not documented and was only caught because the tunnel survived through uptime, not restarts.
2. **Dual tunnel configurations create silent hostname conflicts.** Cloudflare's behavior when two tunnels claim the same hostname is undefined — it depends on which tunnel's CNAME the DNS record points to.
3. **Hard systemd dependencies (`Requires`) on migrated services cause restart failures.** When services move to k8s, their host systemd units should be cleaned up and any dependencies on them removed.
