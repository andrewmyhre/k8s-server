# Incident Report: legal-api-ingestor Memory Leak → Server Crash

**Date:** 2026-03-07
**Host:** `sleeper-service` (single-node homelab Kubernetes cluster)
**Namespace:** `legal-api`
**Service:** `legal-api-ingestor` (WorkflowTemplate + CronWorkflow)

---

## Summary

The `legal-api-ingestor` pipeline caused a full server crash due to a memory leak in the
`parse` and/or `embed` workflow steps. The process grew to 16.7 GB resident memory, hit its
cgroup memory limit, and the resulting OOM pressure caused a kernel panic and unclean reboot.
This happened 4 times in the final boot alone, with memory usage roughly doubling each run.

---

## Crash Evidence

**Confirmed hard/unclean shutdown at ~09:17:47 EST, 2026-03-07:**

- `systemd-journald`: `File system.journal corrupted or uncleanly shut down` on next boot
- `systemd-fsck`: ext4 journal recovery triggered on LVM volume
- `fsck.fat`: `Dirty bit is set. Fs was not properly unmounted`
- Logs cut off abruptly at `09:17:47` — no graceful shutdown messages
- System back online at `09:29:30` (~11.5 minutes downtime)
- `kernel.panic = 10` is set (auto-reboot 10 seconds after kernel panic)

---

## Memory Growth Pattern (Previous Boot)

Kernel OOM kill events for `legal-api-inges` across a single boot, all cgroup-level
(`CONSTRAINT_MEMCG`):

| Timestamp           | PID     | Anon-RSS at kill | Total Virtual Memory |
|---------------------|---------|------------------|----------------------|
| Mar 06 17:25:15     | 2599593 | **8.3 GB**       | 10 GB                |
| Mar 06 19:51:47     | 2743548 | **8.4 GB**       | 10 GB                |
| Mar 06 22:16:57     | 2877105 | **16.7 GB**      | **31 GB**            |
| Mar 07 09:17:47     | (crash) | estimated >16 GB | —                    |

The Mar 05 boot also saw an OOM kill at 4.1 GB. The escalation pattern across boots:
**4 GB → 8 GB → 8 GB → 16 GB → system crash**

Each run, the process pushes to the full cgroup limit before being killed. After Argo
restarts the pod, the next run starts and grows even larger.

---

## Current Configuration

**WorkflowTemplate:** `legal-api-ingestor` in namespace `legal-api`

The `run-ingest` template (used for `parse` and `embed` steps):

```yaml
container:
  image: registry.registry.svc.cluster.local:5000/legal-api:latest
  command: [/legal-api-ingest]
  args: ["{{inputs.parameters.command}}", "--source", "all"]
  env:
    - name: GOMEMLIMIT
      value: "13958643712"   # ~13 GiB soft limit for Go runtime
    - name: GOGC
      value: "50"            # GC aggressiveness (default=100, 50=more frequent)
  resources:
    limits:
      cpu: 2000m
      memory: 16Gi           # hard cgroup limit
    requests:
      cpu: 500m
      memory: 2Gi
  volumeMounts:
    - mountPath: /corpus
      name: corpus           # hostPath: /data/legal-api-corpus
```

**CronWorkflow schedule:** `0 2 * * 0` (Sunday 02:00 UTC, weekly)
**Concurrency policy:** `Forbid`
**Retry strategy on `run-download`:** up to 3 retries, exponential backoff up to 5 min
**No retry strategy on `run-ingest`** (parse/embed steps)

---

## What Is and Isn't Working

The `16Gi` cgroup limit IS being enforced — the kernel kills the container when it reaches
that boundary. However:

1. **`GOMEMLIMIT=13Gi` is not containing the leak.** The Go runtime's soft heap limit should
   trigger aggressive GC at 13 GiB, but the process is growing past it to hit the hard 16 GiB
   ceiling. This suggests the memory growth is either: (a) outside the Go heap (CGo, mmap,
   memory-mapped files, or OS-level allocations), or (b) the GC cannot reclaim fast enough
   because live references are preventing collection.

2. **Each run starts from a larger baseline.** The corpus lives on a shared `hostPath` volume
   (`/data/legal-api-corpus`). If each run accumulates data on disk that the next run loads
   into memory (e.g., all previously parsed/embedded documents), usage will grow with corpus
   size, not just within a single run.

3. **The workflow retries automatically.** After each OOM kill, Argo reschedules the pod.
   Without a memory fix, every retry makes the problem worse.

---

## Crash Timeline

```
Mar 05 20:52  First recorded OOM kill — legal-api-inges at 4.1 GB
Mar 06 17:25  OOM kill — 8.3 GB (doubled)
Mar 06 19:51  OOM kill — 8.4 GB
Mar 06 22:16  OOM kill — 16.7 GB / 31 GB virtual (doubled again)
Mar 07 09:15  Kubelet: disk at 92%, image GC failing
Mar 07 09:17  DNS errors, network stack stress visible in logs
Mar 07 09:17:47  Logs cut off hard — kernel panic / system OOM
              [kernel.panic=10 → auto-reboot 10 seconds later]
Mar 07 09:29:30  System back online after BIOS POST + fsck + boot
```

---

## Recommended Fixes

### 1. Find and fix the memory leak in the ingestor binary

The process is growing beyond what `GOMEMLIMIT` should allow, which points to one of:

- **Unbounded in-memory accumulation** — the parse or embed step may be loading the entire
  corpus into memory at once rather than streaming. Check for slices/maps that accumulate all
  documents before processing.
- **Memory-mapped files** — if the corpus is read via `mmap`, usage won't be reflected in Go
  heap stats and `GOMEMLIMIT` won't help. Look for `syscall.Mmap` or file reading patterns
  that create large byte slices.
- **CGo allocations** — if the ingestor links a C library (e.g., for embeddings), those
  allocations are invisible to the Go GC and `GOMEMLIMIT`.
- **Growing corpus on disk** — if the download step adds to `/data/legal-api-corpus` without
  cleaning up prior runs, each subsequent `parse --source all` processes a larger and larger
  dataset. Add incremental processing or corpus cleanup between runs.

**Diagnostic steps:**
```bash
# Enable Go memory profiling in the binary:
# Add to main.go: go tool pprof http://localhost:6060/debug/pprof/heap
# Or check existing metrics endpoint at :9091 (already exposed)

# Check corpus size growth:
du -sh /data/legal-api-corpus/
find /data/legal-api-corpus -name "*.json" | wc -l
```

### 2. Lower the memory limit as a safety guard

Until the leak is fixed, reduce the hard limit so OOM kills happen before reaching
system-threatening levels. The 3-day pattern shows ~8 GB is survivable, ~16 GB causes
the crash:

```yaml
# In the run-ingest template:
resources:
  limits:
    memory: 8Gi     # was 16Gi
env:
  - name: GOMEMLIMIT
    value: "6442450944"  # 6 GiB — gives Go GC headroom below the 8 GiB ceiling
```

### 3. Add a retry limit on the `run-ingest` template

Currently `parse` and `embed` have no retry strategy. If the process OOMs, Argo will
reattempt immediately. Add a retry limit with backoff so repeated failures fail the
workflow quickly instead of hammering the node:

```yaml
# In the run-ingest template:
retryStrategy:
  limit: "1"
  retryPolicy: "OnError"
  backoff:
    duration: "2m"
    factor: "2"
    maxDuration: "10m"
```

### 4. Add a suspend on repeated workflow failure (optional)

The CronWorkflow has `failedJobsHistoryLimit: 3`. Consider adding a webhook or alert
so repeated failures notify before the next scheduled Sunday run.

---

## Current Status (as of 2026-03-07 09:45 EST)

- Server is back online
- No `legal-api` workflows are currently running
- The `legal-api-ingestor-weekly` CronWorkflow is still active and will next run Sunday 02:00 UTC
- The most recent failed workflows in `legal-api` namespace:

```
full-pipeline-brppv   Failed   2d12h
full-pipeline-5ht79   Failed   47h
full-pipeline-jzp8b   Failed   17h
full-pipeline-svdmc   Failed   15h
parse-embed-b659r     Failed   13h
parse-embed-r8b8t     Failed   11h
```

---

## Files to Look At

| Path | Description |
|------|-------------|
| `k8s/legal-api/workflow-template.yaml` (or equivalent) | WorkflowTemplate source — the applied spec is documented above |
| `/data/legal-api-corpus/` on `sleeper-service` | Corpus hostPath volume — check size and structure |
| Binary: `/legal-api-ingest` in the container image | The `parse` and `embed` subcommands are where the memory growth occurs |
| Container image: `registry.registry.svc.cluster.local:5000/legal-api:latest` | |
