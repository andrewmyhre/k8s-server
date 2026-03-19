# Mullvad VPN Configuration for sleeper-service

## Overview

This server runs Mullvad VPN (WireGuard) alongside a single-node Kubernetes cluster
(Cilium CNI). Mullvad is designed for desktop VPN use, not servers, so several fixes
are required to make it coexist with k8s and allow inbound LAN services (SSH, etc.).

**Server:** sleeper-service (192.168.0.10/16 on enp42s0)
**VPN Exit:** Sweden (WireGuard, quantum-resistant)
**K8s:** Single-node, Cilium CNI, pod CIDR 10.0.0.0/24, service CIDR 10.96.0.0/12

---

## Problems and Root Causes

### Problem 1: LAN Completely Broken (SSH, Ping, All Inbound Services)

**Symptom:** When Mullvad starts, no device on the LAN can ping or SSH to
192.168.0.10. The server can't even ping its own gateway (192.168.0.1). Everything
on the network that touches this server breaks.

**Root cause:** Mullvad moves the `ip rule lookup local` entry from priority 0 to
priority 100 for leak protection. This means the kernel's policy routing checks the
main routing table (priority 98) **before** checking the local table. The main table
has the connected route `192.168.0.0/16 dev enp42s0` (type unicast). When a packet
arrives for 192.168.0.10, the kernel matches this unicast route and treats the packet
as FORWARD instead of INPUT (local delivery). The kernel never recognizes the
destination as a local address because the local table isn't consulted until
priority 100 — by which point the routing decision is already made.

**Evidence (tcpdump while Mullvad connected):**
```
192.168.0.31 > 192.168.0.10: ICMP echo request      <- arrives on wire
192.168.0.10 > 192.168.0.31: ICMP redirect           <- kernel FORWARDs, no echo reply!
```

The ARP table shows `192.168.0.10 INCOMPLETE` (the server can't resolve its own IP
because it's trying to forward to itself).

**Fix:** Add `lookup local` back at priority 0:
```
ip rule add from all lookup local priority 0
```

This restores the kernel's ability to identify local IPs before consulting the main
or VPN routing tables. Mullvad does NOT remove this manually-added rule — both the
priority 0 and priority 100 entries coexist safely.

**Persistence:** `/etc/systemd/system/mullvad-local-route-fix.service`

---

### Problem 2: No Internet Through VPN Tunnel (DNS Broken)

**Symptom:** Mullvad shows "Connected" but all DNS resolution fails. `dig`, `curl`,
and every application that needs DNS times out. The Mullvad daemon itself reports
"Temporary failure in name resolution" for its own API calls.

**Root cause:** The `k8s-dns-bypass.nft` rule used `10.0.0.0/8` to match k8s DNS
traffic that needs to bypass Mullvad's kill switch. But `10.0.0.0/8` also matches
Mullvad's own in-tunnel DNS server at `10.64.0.1`. The bypass marks
(`ct mark 0x00000f41`, `meta mark 0x6d6f6c65`) tell Mullvad's policy routing to
send the packet **outside** the tunnel. So DNS queries to Mullvad's resolver get
routed out the physical NIC instead of through wg0-mullvad — they go nowhere.

**Fix:** Narrow the bypass rule to only match k8s CIDRs:
- `10.0.0.0/24` (pod CIDR)
- `10.96.0.0/12` (service CIDR)

Do **NOT** use `10.0.0.0/8`.

**File:** `/etc/nftables.d/k8s-dns-bypass.nft`

---

### Problem 3: K8s ClusterIP Services Unreachable from Host

**Symptom:** Host processes (kube-apiserver, curl) can't connect to ClusterIP
services (10.96.x.x). Direct pod IPs work fine.

**Root cause:** The service CIDR `10.96.0.0/12` has no route in the main table,
so traffic falls through to Mullvad's VPN routing table, which routes it through
wg0-mullvad with source IP 10.163.105.251 (the VPN tunnel IP). Reply packets from
pods back to this VPN IP are dropped by Mullvad's nftables input chain
(`ip daddr 10.163.105.251 drop`).

**Fix:** Add the service CIDR to the main routing table:
```
ip route add 10.96.0.0/12 via 10.0.0.19 dev cilium_host src 10.0.0.19
```

**Persistence:** `/etc/systemd/system/k8s-svc-route.service`

---

### Problem 4: hostNetwork Pods Can't Resolve DNS

**Symptom:** Pods with `hostNetwork: true` (Plex, etc.) can't resolve DNS.
`sendmmsg` returns EPERM.

**Root cause:** Mullvad's nftables output chain has `udp dport 53 reject` BEFORE
`ip daddr 10.0.0.0/8 accept`. After iptables-nft DNAT (10.96.0.10 -> pod IP),
Mullvad's filter still fires and rejects all port-53 traffic not going to its own
DNS.

**Fix:** The k8s-dns-bypass nftables table sets Mullvad's bypass marks on k8s DNS
traffic at priority `filter - 10` (before Mullvad's filter at priority 0).

**Persistence:** `/etc/systemd/system/k8s-dns-bypass.service`

---

## Working Configuration

### Mullvad Settings

```
Status:              Connected (WireGuard to Sweden)
LAN sharing:         allow
Lockdown mode:       off
Auto-connect:        on
Quantum resistance:  on
DNS:                 default (Mullvad DNS via tunnel at 10.64.0.1)
IPv6 in tunnel:      off
Relay:               country se (Sweden)
```

### IP Policy Rules (correct state)

```
0:     from all lookup local                              <- CRITICAL: must be before 98
9:     from all fwmark 0x200/0xf00 lookup 2004            <- Cilium TPROXY
98:    from all lookup main suppress_prefixlength 0       <- Mullvad: use main for non-default routes
99:    not from all fwmark 0x6d6f6c65 lookup 1836018789   <- Mullvad: VPN routing table
100:   from all lookup local                              <- Mullvad's relocated local table
32766: from all lookup main
32767: from all lookup default
```

### nftables: k8s-dns-bypass

```nft
table inet k8s-dns-bypass {
    chain output {
        type filter hook output priority filter - 10; policy accept;
        # Pod CIDR
        ip daddr 10.0.0.0/24 udp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        ip daddr 10.0.0.0/24 tcp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        # Service CIDR
        ip daddr 10.96.0.0/12 udp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
        ip daddr 10.96.0.0/12 tcp dport 53 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
    }
}
```

### Systemd Services

| Service | File | Purpose | Depends On |
|---------|------|---------|------------|
| mullvad-daemon | (packaged) | Main VPN daemon | - |
| mullvad-local-route-fix | `/etc/systemd/system/mullvad-local-route-fix.service` | Restore `lookup local` at priority 0 | mullvad-daemon |
| k8s-dns-bypass | `/etc/systemd/system/k8s-dns-bypass.service` | Bypass Mullvad DNS block for k8s | mullvad-daemon |
| k8s-svc-route | `/etc/systemd/system/k8s-svc-route.service` | Route 10.96.0.0/12 via cilium_host | network.target |
| sshd-lan | `/etc/systemd/system/sshd-lan.service` | LAN-only SSH on 192.168.0.10:22 | mullvad-daemon |
| mullvad-startup-fix | `/etc/systemd/system/mullvad-startup-fix.service` | Clear stale WG interfaces on boot | - |

### Config Files

| File | Purpose |
|------|---------|
| `/etc/mullvad-vpn/settings.json` | Mullvad settings (allow_lan, relay, quantum_resistant) |
| `/etc/nftables.d/k8s-dns-bypass.nft` | nftables rules for k8s DNS bypass |
| `/etc/ssh/sshd_config_lan` | SSH config bound to 192.168.0.10 |
| `/etc/clear-mullvad-wg.sh` | Script to down stale WG interfaces |

---

## Key Concepts

### Mullvad's Mark System
- `ct mark 0x00000f41` + `meta mark 0x6d6f6c65` ("mole" in ASCII) = bypass VPN
- Packets with these marks are allowed through Mullvad's kill switch and routed
  outside the tunnel via the physical interface

### Mullvad's Routing Tables
- Table `1836018789`: VPN routing — `default dev wg0-mullvad`
- `suppress_prefixlength 0`: Use main table for everything EXCEPT default route
- Non-marked traffic uses Mullvad table (VPN), marked traffic uses main (bypass)

### Why This Is Hard
Mullvad is designed for desktop VPN, not servers. Key assumptions it makes:
1. No inbound connections needed (moved `lookup local` to priority 100)
2. All DNS goes through the tunnel (kills port 53 in output chain)
3. Only RFC1918 LAN traffic is allowed (but this works fine with `allow_lan`)
4. No other routing complexity (k8s adds service CIDR, pod CIDR, policy routing)

---

## Testing

A test script is at `/usr/local/bin/mullvad-test`. It starts Mullvad, waits 30s for
connectivity, and auto-stops if it fails. Use this instead of manually
starting/stopping the daemon.

### Manual verification checklist
```bash
# VPN connected
mullvad status                              # Should show "Connected"
curl -s https://am.i.mullvad.net/connected  # Should confirm Mullvad

# LAN works
ping -c 1 192.168.0.1                       # Gateway reachable
ssh 192.168.0.10                             # From another LAN device

# Internet works through tunnel
ping -c 1 1.1.1.1                           # ~90ms via Sweden
dig +short google.com                        # DNS resolves

# K8s works
kubectl get nodes                            # Ready
dig +short kubernetes.default.svc.cluster.local @10.96.0.10  # CoreDNS works
curl -sk https://10.96.0.1:443              # API server reachable via ClusterIP

# IP rules correct
ip rule show                                 # Priority 0: lookup local must exist
```

---

## Troubleshooting

### "Everything broke when Mullvad started"
Check `ip rule show`. If priority 0 `lookup local` is missing:
```bash
sudo ip rule add from all lookup local priority 0
```

### DNS doesn't work
Check that `/etc/nftables.d/k8s-dns-bypass.nft` uses `10.0.0.0/24` and
`10.96.0.0/12`, **NOT** `10.0.0.0/8`.

### K8s ClusterIP unreachable
```bash
ip route show | grep 10.96
# Should show: 10.96.0.0/12 via 10.0.0.19 dev cilium_host src 10.0.0.19
```

### Emergency: stop Mullvad
```bash
sudo systemctl stop mullvad-daemon
```
This removes all Mullvad nftables rules and restores normal routing.

---

*Last updated: 2026-03-09. Fixes applied by Rik during troubleshooting session.*
