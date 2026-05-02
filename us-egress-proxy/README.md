# us-egress-proxy

An HTTP/HTTPS proxy running on `sleeper-service` whose egress traffic
**bypasses Mullvad VPN**, giving cluster workloads a way to reach APIs that
block non-US IPs without taking the whole cluster off the VPN.

## How it works

```
 ┌────────────── Kubernetes ───────────────┐
 │  pod (envFrom: us-egress-proxy-creds)   │
 │    │                                    │
 │    │  HTTPS_PROXY=http://192.168.0.10:8888
 │    ▼                                    │
 └──┬──────────────────────────────────────┘
    │  (in-cluster hop)
 ┌──▼─────────────────── sleeper-service ──────────────────┐
 │  tinyproxy (runs as user `tinyproxy`, bound to LAN IP)  │
 │    │                                                    │
 │    │  outbound socket                                   │
 │    ▼                                                    │
 │  nftables table `us-egress-proxy` (priority filter-10)  │
 │    meta skuid "tinyproxy"                               │
 │      ct mark   set 0x00000f41                           │
 │      meta mark set 0x6d6f6c65  ("mole")                 │
 │    │  (applies to DNS and data plane alike)             │
 │    ▼                                                    │
 │  Mullvad policy routing: marked packets skip the tunnel │
 │    → enp42s0 → ISP gateway → public internet (US IP)    │
 └─────────────────────────────────────────────────────────┘
```

Same mark scheme and priority used by the existing `k8s-dns-bypass` —
see [../mullvad-vpn-configuration.md](../mullvad-vpn-configuration.md)
for the theory.

### Why DNS also gets the mole marks (and needs a custom resolver)

Two constraints collide:

1. Mullvad's OUTPUT filter has `udp dport 53 reject` firing on **all**
   port-53 traffic, even loopback — see Problem 4 in
   `mullvad-vpn-configuration.md`. An unmarked DNS query from tinyproxy
   never escapes the host. So DNS **must** be marked.
2. Marked traffic bypasses the tunnel. Mullvad's in-tunnel DNS at
   `10.64.0.1` is only reachable inside the tunnel. So tinyproxy **cannot**
   use the host's default resolver (systemd-resolved → `10.64.0.1`).

Resolution: tinyproxy is pointed at Cloudflare's public anycast resolver
(`1.1.1.1`), which IS reachable over the bypass path. This is done with a
systemd drop-in that `BindReadOnlyPaths`-mounts
`/etc/us-egress-proxy/resolv.conf` over `/etc/resolv.conf` inside tinyproxy's
mount namespace. Nothing else on the host is affected — systemd-resolved
continues to answer on `127.0.0.53` for everyone else using Mullvad's DNS.

## Files

```
us-egress-proxy/
├── README.md                              # this file
├── host/                                  # deployed on sleeper-service
│   ├── tinyproxy.conf                     # proxy config (LAN-bound, basic auth)
│   ├── tinyproxy-resolv.conf              # overridden resolv.conf (1.1.1.1)
│   ├── tinyproxy-service-override.conf    # systemd drop-in bind-mounting it
│   ├── us-egress-proxy-bypass.nft         # nft rule marking tinyproxy's packets
│   ├── us-egress-proxy-bypass.service     # systemd unit that loads the nft rule
│   └── install.sh                         # one-shot installer (run as root)
└── k8s/
    ├── seal-credentials.sh                # generates a SealedSecret per ns
    └── example-consumer.yaml              # reference Deployment pattern
```

## Install

### 1. Host setup (once, on sleeper-service)

```bash
scp -r host/ sleeper-service:/tmp/us-egress-proxy-host
ssh sleeper-service 'sudo /tmp/us-egress-proxy-host/install.sh'
```

The installer:

1. Installs `tinyproxy` + `nftables` + `dnsutils`.
2. Drops the nft rule into `/etc/nftables.d/us-egress-proxy-bypass.nft`.
3. Generates a random 32-char password.
4. Writes `/etc/tinyproxy/tinyproxy.conf` with the password substituted.
5. Enables + starts `us-egress-proxy-bypass.service` and `tinyproxy.service`.
6. Runs four verifications, each with a distinct error message so a failure
   tells you exactly where to look:
   - nft table loaded
   - tinyproxy listening on `192.168.0.10:8888`
   - DNS resolves from the `tinyproxy` UID (proves port-53 exemption works)
   - end-to-end curl through the proxy reports a non-Mullvad IP
7. Prints the password so it can be sealed into k8s.

**Keep the password it prints.** You need it for step 2.

### 2. Per-namespace k8s setup (for each consuming workload)

```bash
cd k8s/
PROXY_PASSWORD='<the password install.sh printed>' \
    ./seal-credentials.sh <target-namespace>

kubectl apply -f us-egress-proxy-creds-<target-namespace>-sealed.yaml
```

Commit the sealed YAML to the repo.

**Delete the local plaintext** (including any shell history entries) once the
SealedSecret is applied. Per the project rules, plaintext credentials must
not persist outside the cluster / SealedSecret.

### 3. Wire it into the consuming Deployment

See [`k8s/example-consumer.yaml`](k8s/example-consumer.yaml) for the full
pattern. The minimum is:

```yaml
envFrom:
  - secretRef:
      name: us-egress-proxy-creds
env:
  - name: NO_PROXY
    value: .cluster.local,.svc,10.0.0.0/8,192.168.0.0/16
```

The `NO_PROXY` entry is **not optional** — without it, in-cluster traffic to
ClusterIPs would also try to route through the proxy and fail.

## Verification

From sleeper-service:

```bash
# DNS should resolve from the tinyproxy UID
sudo -u tinyproxy dig am.i.mullvad.net +short

# Proxied egress should report a non-SE country
curl -x http://proxyuser:<pw>@192.168.0.10:8888 https://ipinfo.io/country

# Direct (non-proxied) egress should still use Mullvad (SE)
curl https://ipinfo.io/country
```

From a pod in the consuming namespace:

```bash
kubectl -n <ns> run proxy-test --rm -it --image=curlimages/curl:8.8.0 \
    --overrides='{"spec":{"containers":[{"name":"proxy-test","image":"curlimages/curl:8.8.0","stdin":true,"tty":true,"envFrom":[{"secretRef":{"name":"us-egress-proxy-creds"}}],"env":[{"name":"NO_PROXY","value":".cluster.local,.svc,10.0.0.0/8,192.168.0.0/16"}]}]}}' \
    -- sh -c 'curl -s https://ipinfo.io/country'
# Expect: US
```

## Operational notes

- **Mullvad version churn.** The bypass depends on two things staying true:
  Mullvad's mole mark constants (`0x00000f41` / `0x6d6f6c65`) and the
  `meta skuid "tinyproxy"` match. Check the Mullvad release notes before
  major upgrades.
- **Log volume.** tinyproxy logs at `Info` to `/var/log/tinyproxy/`. If this
  gets noisy, drop to `Warning` in `tinyproxy.conf`.
- **Killswitch interaction.** Mullvad's killswitch permits LAN traffic
  (`allow_lan = true` in settings.json). If someone ever flips that off,
  pods on `10.0.0.0/24` can still reach `192.168.0.10` because cilium_host
  is on-host, but the `Allow` lines in tinyproxy.conf are your second
  line of defence.
- **Port restriction.** `ConnectPort 443` means this proxy only tunnels to
  HTTPS. If the target API uses something else, add the port explicitly
  (do not broaden to all ports).
- **Single point of trust.** Anything with the credentials can use the
  proxy to egress from a US IP. If the password leaks, re-run
  `host/install.sh` with a new `PROXY_PASSWORD`, re-seal for each
  namespace, re-apply.

## Why not `mullvad-exclude`?

Mullvad ships an `mullvad-exclude` / `mullvad split-tunnel` feature that does
the same thing via cgroup classification. It works, but:

1. The existing host setup already uses nftables + mole marks heavily (see
   `k8s-dns-bypass`). Staying in that pattern means one mental model and one
   debugging path, not two.
2. cgroup-based exclusion has changed between Mullvad versions (cgroup v1
   net_cls → cgroup v2 + eBPF). The `meta skuid` match is stable across
   Mullvad releases.
3. The nft rule is declarative and visible in `nft list ruleset`; the
   cgroup approach is invisible unless you know to look for it.

If this ever stops working and Mullvad's marks change, switching to
`mullvad-exclude` in the systemd unit is a one-line fix.
