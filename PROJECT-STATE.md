# k8s-server — Complete Project State

> **Purpose of this document:** Comprehensive snapshot of the cluster's configuration, deployed
> applications, networking quirks, secrets, monitoring, and known issues. Intended to restore
> full working context in a new conversation after history is lost.
>
> **Last updated:** 2026-03-30

---

## 1. Cluster Overview

| Property | Value |
|----------|-------|
| Node | `sleeper-service` (192.168.0.10) |
| k8s version | v1.35.2 |
| Container runtime | containerd 2.2.1 |
| OS | Ubuntu 24.04.4 LTS |
| Control plane | Single-node (control-plane + workload) |
| RAM | ~54 GB |
| CPU | ~11.8 cores |
| Disk | ~457 GB (~92% full — critical) |
| CNI | Cilium |
| Pod CIDR | 10.0.0.0/24 |
| Service CIDR | 10.96.0.0/12 |
| StorageClass | `local-path` (Rancher local-path provisioner, default) |
| Ingress | nginx (NodePort 30080/30443) |
| Kubeconfig | `/home/andrew/admin.conf` |
| Helm binary | `/home/linuxbrew/.linuxbrew/Cellar/helm/4.1.1/bin/helm` |

---

## 2. Domain Names

| Domain | Use |
|--------|-----|
| `*.immutablesoftware.dev` | Infrastructure / developer tools (default) |
| `*.primera.rodeo` | Media apps |

All ingresses use `ingressClassName: nginx`.

---

## 3. External Access — Cloudflare

### Cloudflare Tunnel

- **Tunnel ID:** `6c51f837-c566-45d2-b0ab-669f416ffbc4`
- **Deployment:** `cloudflare/cloudflared` — 2 replicas, image `cloudflare/cloudflared:latest`
- **Token secret:** `cloudflared-token` (SealedSecret → key `token` → env `TUNNEL_TOKEN`)
- **Manifest:** `k8s-apps/cloudflare/cloudflared-deployment.yaml`

### Cloudflare Access (Zero Trust Auth)

All services protected by Cloudflare Access before traffic reaches nginx. No auth config needed in-cluster.

| App | URL | CF App ID |
|-----|-----|-----------|
| Argo Workflows | https://argo-workflows.immutablesoftware.dev | f8943adb-eaa5-432d-9381-0ff455bdbd62 |
| Grafana | https://grafana.immutablesoftware.dev | e8e7f4bf-4088-4e65-999a-3c923dd4ca45 |
| Headlamp | https://headlamp.immutablesoftware.dev | (CF Access protected) |

- **Policy:** Email = `andrew.myhre@gmail.com`, OTP auth, 24h sessions
- **CF Zero Trust dashboard:** https://one.dash.cloudflare.com/

---

## 4. Monitoring Stack (`monitoring` namespace)

All Helm values in `monitoring/`. Full stack installer: `monitoring/install.sh`.

### Helm Charts

| Component | Chart | Version | URL |
|-----------|-------|---------|-----|
| kube-prometheus-stack | prometheus-community/kube-prometheus-stack | v82.5.0 | grafana.immutablesoftware.dev |
| Loki | grafana/loki | v6.53.0 | in-cluster only (port 3100) |
| Fluent Bit | fluent/fluent-bit | v0.56.0 | DaemonSet |
| Elasticsearch | elastic/elasticsearch | 8.5.1 | in-cluster only (port 9200) |
| Kibana | elastic/kibana | 8.5.1 | kibana.immutablesoftware.dev |
| metrics-server | metrics-server/metrics-server | v3.13.0 | kube-system namespace |

### kube-prometheus-stack

Values file: `monitoring/kube-prometheus-stack-values.yaml`

Key config:
- Grafana persistence: 5Gi `local-path`
- Prometheus retention: 30d, storage: 20Gi `local-path`
- Alertmanager storage: 2Gi `local-path`
- Grafana admin password: `admin` (change on first login)
- `initChownData.enabled: false` — Grafana creates `png/csv/pdf` subdirs as mode 700; the init container has only `CAP_CHOWN` (not `CAP_DAC_OVERRIDE`) and can't traverse them after a crash
- Loki added as additionalDataSource (http://loki.monitoring.svc.cluster.local:3100)

**Helm upgrade known issue:** Upgrades hang due to ~35 PrometheusRules each triggering the validation webhook on port 10250 (same port as kubelet). Resources ARE applied before the hang. Fix:
1. Confirm pods are healthy
2. Find the latest Helm release secret: `kubectl get secrets -n monitoring | grep sh.helm.release.v1.kube-prometheus-stack`
3. Decode base64×2 + gunzip → set `info.status="deployed"` → gzip + base64×2 → `kubectl patch secret`

### Loki

Values file: `monitoring/loki-values.yaml`

- Single-binary mode (no distributed components)
- Storage: filesystem, 20Gi `local-path`
- Schema: tsdb v13 (from 2024-01-01)
- Auth disabled
- lokiCanary enabled for health checking

### Fluent Bit

Values file: `monitoring/fluent-bit-values.yaml`

- DaemonSet, collects from `/var/log/containers/*.log` with CRI multiline parser
- **Single output: Loki** (`loki.monitoring.svc.cluster.local:3100`)
  - Note: Memory also previously shipped to Elasticsearch but current values show Loki only
- Labels: namespace, pod name, container name

### Elasticsearch

- Security DISABLED (`xpack.security.enabled: false`)
- GeoIP downloader disabled
- Disk watermarks raised: low=95%, high=97%, flood=99% (disk ~92% full)
- Single-node index template → `number_of_replicas: 0`
- `elasticsearch-master-certs`: dummy secret (Kibana chart requires it)
- `kibana-kibana-es-token`: dummy token (chart requires it, ES ignores it with security off)

### Kibana

- Installed with `--no-hooks` (pre-install hook hardcoded to HTTPS, breaks with security disabled)
- URL: kibana.immutablesoftware.dev

### metrics-server

Values file: `monitoring/metrics-server-values.yaml`

- `hostNetwork: true` + port 4443 (workaround; ClusterIP can't reach port 10250 due to Mullvad; see §6)
- Args: `--kubelet-insecure-tls`, `--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname`

---

## 5. Grafana Alerting

**Current branch:** `feat/grafana-alerting` (in progress, not yet merged to main)

### Architecture

Grafana 12 unified alerting. Two-part provisioning split:

1. **Contact points + notification policy** (sensitive — contains Slack token):
   - `k8s-apps/monitoring/grafana-alerting-provisioning-sealed.yaml` (SealedSecret)
   - Decrypted by init container → copied to `/etc/grafana/provisioning/alerting/`

2. **Alert rules** (non-sensitive):
   - `k8s-apps/monitoring/grafana-alert-rules.yaml` (ConfigMap)
   - Copied by same init container

### Why this architecture

Grafana 12 alerting provisioning does NOT support `$__env{VAR}` or `${VAR}` env var substitution in contact point settings fields. The token validation fires at parse time. Solution: embed secrets directly in the provisioning YAML at seal time.

Grafana chart v11 `extraVolumes` silently falls through to `emptyDir: {}` for secret-type volumes (only handles `existingClaim`, `hostPath`, `csi`, `configMap`, `emptyDir`). Must use `extraContainerVolumes` instead.

### Contact Points

- **Contact point name:** "All Alerts"
- **Slack:** channel `#automation`, PAI bot token (embedded in provisioning SealedSecret)
- **Email:** `andrew.myhre@gmail.com` via Amazon SES

### SMTP (Amazon SES)

- Host: `email-smtp.us-east-1.amazonaws.com:587`
- From: `alerts@immutablesoftware.dev`
- Credentials: `grafana-alerting-credentials` SealedSecret → env vars `GF_SMTP_USER`, `GF_SMTP_PASSWORD`
- `envFromSecret: grafana-alerting-credentials` (chart key — single string, NOT `envFrom` list)

### Notification Policy

Default policy → "All Alerts": 30s group wait, 4h repeat interval

### Alert Rules (current)

| Rule UID | Title | Condition | For |
|----------|-------|-----------|-----|
| `disk-usage-high` | High Disk Usage (> 85%) | >85% non-tmpfs filesystem usage | 5m |

---

## 6. Networking — Mullvad VPN

The server runs Mullvad VPN (WireGuard to Sweden, quantum-resistant) alongside k8s. Mullvad is designed for desktop use and requires several fixes to coexist.

**Full documentation:** `mullvad-vpn-configuration.md`

### Four Problems and Fixes

#### Problem 1: LAN completely broken when Mullvad starts
- **Root cause:** Mullvad moves `ip rule lookup local` from priority 0 → 100. Main table unicast route for 192.168.0.0/16 matches BEFORE local table → kernel treats inbound LAN packets as FORWARD instead of INPUT → ICMP redirects instead of delivery.
- **Fix:** `ip rule add from all lookup local priority 0`
- **Persistence:** `/etc/systemd/system/mullvad-local-route-fix.service`
- **IMPORTANT:** This service has NO `ExecStop`. Without that, Mullvad's cleanup code skips re-adding the rule on daemon stop, then ExecStop removes it last → stuck at priority 100.
- **WantedBy:** both `multi-user.target` AND `mullvad-daemon.service` (activates on boot AND manual daemon start)

#### Problem 2: DNS broken / all internet fails
- **Root cause:** `k8s-dns-bypass.nft` using `10.0.0.0/8` catches Mullvad's own DNS at `10.64.0.1`, routing it outside the tunnel.
- **Fix:** Use ONLY `10.0.0.0/24` (pod CIDR) and `10.96.0.0/12` (service CIDR) — **NEVER `10.0.0.0/8`**
- **File:** `/etc/nftables.d/k8s-dns-bypass.nft`

#### Problem 3: ClusterIP services unreachable from host
- **Root cause:** `10.96.0.0/12` has no route in main table → falls through to Mullvad VPN table → source IP becomes `10.143.32.4` (wg0-mullvad) → Mullvad drops reply packets.
- **Fix:** `ip route add 10.96.0.0/12 via 10.0.0.19 dev cilium_host src 10.0.0.19`
- **Persistence:** `/etc/systemd/system/k8s-svc-route.service` (polls for `10.0.0.19` on `cilium_host` before adding)

#### Problem 4: hostNetwork pods can't resolve DNS
- **Root cause:** Mullvad output chain has `udp dport 53 reject` BEFORE `ip daddr` accept rules. After iptables DNAT, Mullvad still rejects port-53 traffic.
- **Fix:** Set bypass marks at `filter - 10` priority (before Mullvad's filter at 0)
- **Persistence:** `/etc/systemd/system/k8s-dns-bypass.service`

### nftables k8s-dns-bypass rules

```nft
table inet k8s-dns-bypass {
    chain output {
        type filter hook output priority filter - 10; policy accept;
        ip daddr 10.0.0.0/24 udp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        ip daddr 10.0.0.0/24 tcp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        ip daddr 10.96.0.0/12 udp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        ip daddr 10.96.0.0/12 tcp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
    }
}
```

### IP Rule Table (correct state)

```
0:     from all lookup local                              ← CRITICAL: must be at 0
9:     from all fwmark 0x200/0xf00 lookup 2004            ← Cilium TPROXY
98:    from all lookup main suppress_prefixlength 0       ← Mullvad
99:    not from all fwmark 0x6d6f6c65 lookup 1836018789   ← Mullvad VPN table
100:   from all lookup local                              ← Mullvad's relocated entry
32766: from all lookup main
32767: from all lookup default
```

### Mullvad Systemd Services

| Service | Purpose | Enabled |
|---------|---------|---------|
| `mullvad-daemon` | Main VPN daemon | yes |
| `mullvad-local-route-fix` | Restore lookup local at priority 0 | yes |
| `k8s-dns-bypass` | Bypass Mullvad DNS block for k8s | yes |
| `k8s-svc-route` | Route 10.96.0.0/12 via cilium_host | yes |
| `sshd-lan` | LAN-only SSH on 192.168.0.10:22 | yes |
| `mullvad-startup-fix` | Clear stale WG interfaces on boot | yes |
| `clear-mullvad-wg` | Legacy startup fix | disabled |

### Mullvad Settings

```
Status: Connected (WireGuard to Sweden)
LAN sharing: allow
Lockdown mode: off
Auto-connect: on
Quantum resistance: on
DNS: default (Mullvad DNS via tunnel at 10.64.0.1)
```

### Quick Verification

```bash
mullvad status                               # Connected
ping -c1 192.168.0.1                         # LAN works
ip rule show | grep "0:.*lookup local"       # Priority 0 rule exists
ip route show | grep 10.96                   # ClusterIP route exists
kubectl get nodes                            # Ready
```

---

## 7. Secrets — Sealed Secrets

### Controller

- **Chart:** `sealed-secrets/sealed-secrets` v0.36.1
- **Namespace:** `kube-system`
- **Release name:** `sealed-secrets-controller`
- **Image:** `bitnami/sealed-secrets-controller:0.36.1`
- **CLI:** `/usr/local/bin/kubeseal`
- **Values:** `k8s-apps/sealed-secrets-values.yaml`

### Sealing Workflow

```bash
# Seal a secret
kubeseal --format yaml < secret.yaml > sealed-secret.yaml

# Apply
kubectl apply -f sealed-secret.yaml
```

All sealed files under `k8s-apps/<namespace>/*-sealed.yaml`.

### Secrets Inventory

| Namespace | Secret Name | Sealed File | Keys |
|-----------|-------------|-------------|------|
| cloudflare | `cloudflared-token` | `cloudflare/cloudflared-token-sealed.yaml` | `token` |
| headlamp | `headlamp-kubeconfig` | `headlamp/headlamp-kubeconfig-sealed.yaml` | `config` |
| kubenav | `dashboard-admin-token` | `kubenav/dashboard-admin-token-sealed.yaml` | `token` |
| huddle | `huddle-api-secrets` | `huddle/huddle-api-secrets-sealed.yaml` | `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` |
| legal-api | `legal-api-secrets` | `legal-api/legal-api-secrets-sealed.yaml` | `ANTHROPIC_API_KEY`, `API_KEY`, `DATABASE_URL`, `GOVINFO_API_KEY`, `POSTGRES_PASSWORD`, `VOYAGE_AI_API_KEY` |
| legal-ingestor | `ingestor-secrets` | `legal-ingestor/ingestor-secrets-sealed.yaml` | `ADMIN_API_URL`, `ANTHROPIC_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_REGION`, `AWS_SECRET_ACCESS_KEY`, `DOCUMENTS_BUCKET`, `GOVINFO_API_KEY`, `INGESTOR_SECRET`, `VOYAGE_AI_API_KEY` |
| monitoring | `grafana-alerting-credentials` | `monitoring/grafana-alerting-sealed.yaml` | `GF_SMTP_USER`, `GF_SMTP_PASSWORD`, `GF_SLACK_TOKEN` |
| monitoring | `grafana-alerting-provisioning` | `monitoring/grafana-alerting-provisioning-sealed.yaml` | Full provisioning YAML with Slack token embedded |

> **Rule:** Never print secret values in output or terminal. Redact when reading secrets files.

### RBAC

`ClusterRole/agent-secret-reader` (get/list secrets) bound per-namespace via `RoleBinding` for `ServiceAccount/agent` in:
- cloudflare, huddle, legal-api, legal-ingestor, headlamp, kubenav

Manifest: `k8s-apps/rbac/agent-secret-reader.yaml`

---

## 8. Deployed Applications

### Argo Workflows (`argo` namespace)

- **Chart:** `argo/argo-workflows`
- **Values:** `argo/argo-workflows-values.yaml`
- **Ingress:** `argo/ingress.yaml` → `argo-workflows.immutablesoftware.dev`
- **Auth mode:** `--auth-mode=server` (Cloudflare Access handles perimeter auth)
- **Workflow namespaces watched:** `argo`, `legal-ingestor`
- **TTL:** 1h after completion/success, 24h after failure
- **Backend protocol:** HTTP (nginx annotation `backend-protocol: HTTP`)

### Headlamp (`headlamp` namespace)

- **Chart:** `headlamp/headlamp`
- **Values:** `k8s-apps/headlamp-values.yaml`
- **URL:** https://headlamp.immutablesoftware.dev
- **Secret:** `headlamp-kubeconfig` — cluster-admin kubeconfig (highly sensitive)
- Auth: Cloudflare Access

### KubeNav (`kubenav` namespace)

- **Chart:** `kubenav/kubenav`
- **Values:** `k8s-apps/kubenav-values.yaml`
- **Secret:** `dashboard-admin-token` — cluster-admin bearer token (highly sensitive)

### Cloudflared (`cloudflare` namespace)

- Deployment with 2 replicas
- Token from `cloudflared-token` SealedSecret
- See §3 for full Cloudflare details

### Huddle (`huddle` namespace)

- PAI collaborative session system
- Secrets: Anthropic API key, ElevenLabs API key, VAPID credentials

### Legal API (`legal-api` namespace)

- Backend service for legal document processing
- Secrets: Anthropic, Voyage AI, GovInfo API keys + PostgreSQL credentials
- Shares database with `legal-ingestor`

### Legal Ingestor (`legal-ingestor` namespace)

- Argo Workflow (CronWorkflow) — ingests legal documents from govinfo.gov → S3 + database
- Schedule: `0 2 * * 0` (Sunday 02:00 UTC, weekly)
- **CRITICAL KNOWN ISSUE:** See §9

---

## 9. Known Issues

### 9.1 Legal-API-Ingestor Memory Leak (CRITICAL — UNFIXED)

**Status:** Memory limit set to 16Gi but leak is unfixed. Next run: Sunday 02:00 UTC.

**History:**
- 2026-03-05: First OOM kill at 4.1 GB
- 2026-03-06: OOM kills at 8.3 GB, 8.4 GB, 16.7 GB
- 2026-03-07 09:17 EST: **System crash** (kernel panic → auto-reboot, ~11.5 min downtime)

**Pattern:** Memory roughly doubles each run: 4 GB → 8 GB → 8 GB → 16 GB → crash

**Root cause options:**
- Unbounded in-memory accumulation (loading entire corpus instead of streaming)
- Memory-mapped files (`mmap` — invisible to Go GC / `GOMEMLIMIT`)
- CGo allocations (if C library used for embeddings)
- Growing corpus on disk — `parse --source all` processes larger dataset each run

**Recommended fixes (not yet applied):**
1. Reduce hard limit to 8Gi and `GOMEMLIMIT` to 6Gi as safety guard
2. Add retry limit to `run-ingest` template (`limit: "1"`, backoff 2-10m)
3. Find and fix the actual memory leak in the binary

**Full incident report:** `incident-report-legal-api-ingestor-2026-03-07.md`

### 9.2 Disk at ~92% (Critical)

- Kubelet image GC failing: `92% of 456.3 GiB used, failed to free sufficient space`
- Elasticsearch watermarks raised to 95/97/99% as workaround
- Alert rule for >85% is configured but disk was already over threshold when added

**Cleanup options:**
```bash
# Check what's large
du -sh /var/lib/containerd/
kubectl get pv -o wide
du -sh /data/legal-api-corpus/
```

### 9.3 tmux /tmp Permissions After Hard Reboots

After unclean shutdowns, `/tmp/tmux-1000` gets created as `root:root 0755` during early boot.

**Immediate fix:**
```bash
sudo chown andrew:andrew /tmp/tmux-1000 && sudo chmod 700 /tmp/tmux-1000
```

**Permanent fix (applied):**
```bash
echo 'd /tmp/tmux-1000 0700 andrew andrew -' | sudo tee /etc/tmpfiles.d/tmux-andrew.conf
```

---

## 10. Current Git State (2026-03-30)

**Active branch:** `feat/grafana-alerting`

**Uncommitted changes:**
- `M argo/argo-workflows-values.yaml` — modified
- `M k8s-apps/monitoring/grafana-alert-rules.yaml` — modified

**Recent merged work:**
- Grafana unified alerting with Slack + email contact points
- Disk usage alert rule (>85% for 5m)
- Sealed Secrets controller + all app secrets migrated
- metrics-server values + Grafana initChownData fix
- Mullvad VPN documentation + incident report
- RBAC agent-secret-reader for all app namespaces
- Cloudflare, Headlamp, KubeNav Helm configs

**Pending / not yet merged to main:**
- `feat/grafana-alerting` branch — Grafana alerting setup

---

## 11. Helm Repos Required

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

---

## 12. Gotchas and Hard-Won Lessons

### Grafana Chart v11

- `extraVolumes` silently ignores secret-type volumes (only handles `existingClaim`, `hostPath`, `csi`, `configMap`, `emptyDir`) → use `extraContainerVolumes` instead
- `envFromSecret: <name>` is a single string, NOT `envFrom: [{secretRef: {name: ...}}]`

### Grafana 12 Alerting Provisioning

- No env var substitution in contact point settings (`$__env{VAR}` is for dashboards/datasources only)
- Token validation fires at parse time → must embed secrets directly in provisioning YAML
- Use init container pattern: SealedSecret with full YAML → emptyDir → Grafana reads at startup
- The `alerting:` key in chart values creates an `alerting-provisioning` emptyDir automatically — removing `alerting:` removes the volume; if using init-container approach, define the emptyDir explicitly in `extraContainerVolumes`

### kube-prometheus-stack Upgrades

- Hang because ~35 PrometheusRules trigger validation webhook on port 10250 (kubelet port)
- Resources ARE applied before hang — upgrade is effectively complete
- Fix via patching Helm release secret status to `"deployed"`

### Sealed Secrets

- If the sealed-secrets controller is destroyed and recreated, all existing SealedSecrets become unreadable (key pair changes) — back up the controller's key pair: `kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key`

### Disk Space

- At ~92%, image GC is failing. Don't create large PVCs or pull large images without first freeing space.
- `/data/legal-api-corpus` may be growing unchecked — check before running legal-ingestor again.

---

## 13. AI Git Identity (for this repo)

All AI commits must use:
```bash
git commit --author="kit-pai-app[bot] <259931674+kit-pai-app[bot]@users.noreply.github.com>"
```

For GitHub write operations (PRs, issues):
```bash
~/.claude/scripts/kit-gh pr create ...
~/.claude/scripts/kit-gh issue create ...
```
