---
name: k8s-server / Cluster Health
order: 15
active: true
schedule: always
expires:
---

## Data Sources

- `~/projects/k8s-server/.daily/systemd-pending.txt` — systemd/udev packages held back from auto-upgrade (written nightly by cron)

## Commands

- `kubectl get nodes -o wide`
- `kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | grep -v "Completed\|NAME" || echo "All pods healthy"`
- `kubectl top nodes 2>/dev/null || echo "(metrics unavailable)"`
- `kubectl top pods --all-namespaces --sort-by=memory 2>/dev/null | head -20 || echo "(metrics unavailable)"`
- `kubectl get events --all-namespaces --field-selector=reason=OOMKilling --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo "No OOM events"`
- `kubectl get workflows --all-namespaces --field-selector=status.phase=Failed -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,AGE:.metadata.creationTimestamp' 2>/dev/null | head -10 || echo "No failed workflows"`
- `kubectl get events --all-namespaces --field-selector=type=Warning --sort-by='.lastTimestamp' 2>/dev/null | grep -v "FailedCreatePodSandBox\|BackOff" | tail -15 || echo "No warnings"`
- `df -h / 2>/dev/null | tail -1`

## Instructions

Summarize the health of the `sleeper-service` k8s homelab cluster.

Known baselines:
- Single-node: `sleeper-service` (control-plane) — ~54GB RAM, ~11.8 CPU, 457GB disk
- Disk is chronically ~90% full — flag at ≥93%, critical at ≥96%
- Memory: flag if node shows >90% used
- Known recurring issue: `legal-api-ingestor` (namespace: `legal-api`) has a memory leak and OOM-kills frequently — this is expected but worth surfacing if it happened in the last 24h
- systemd/udev are intentionally blocked from auto-upgrade — the `systemd-pending.txt` file lists any held-back versions

Flag if:
- Any pod is in CrashLoopBackOff or Error state (not Completed/Succeeded)
- Disk ≥ 93% used
- Memory ≥ 90% used on node
- Any OOM events for pods OTHER than `legal-api-ingestor`
- Any Argo Workflows in Failed state

If all systems nominal, keep the block brief ("✅ Cluster healthy — no action needed").

## Output Format

IMPORTANT: Use exactly `## k8s-server / Cluster Health` as the top-level heading. Do NOT add "Block N:" or any numbering prefix.

## k8s-server / Cluster Health
*Owner: Rik | Priority: [LOW / MEDIUM / HIGH based on findings]*

**Node:** [Ready / NotReady] — [CPU%] CPU, [mem%] mem, disk [X%]
**Pods:** [N unhealthy / all healthy]
**OOM events (24h):** [none / list]
**Argo failures:** [none / list]
**Systemd pending:** [none / list packages]
- [ ] [Flagged action if anomaly, otherwise "✅ No action needed"]
