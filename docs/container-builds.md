# Container Builds in the Homelab Cluster

How agents and CI pipelines build container images inside the cluster.

---

## What's Deployed

Two pieces of infrastructure work together to give in-cluster pods the ability to build and store container images without needing a Docker daemon, root, or `/var/run/docker.sock`.

### 1. BuildKit daemon

Rootless OCI image builder. Pods send build requests to it over plain TCP.

| | |
|---|---|
| **Helm release** | `buildkitd` |
| **Chart** | `buildkit-service-1.4.0` |
| **Image** | `moby/buildkit:v0.28.1` |
| **Namespace** | `buildkit` |
| **Service** | `buildkitd.buildkit.svc.cluster.local:1234` (TCP, plain — no TLS) |
| **Auth** | None at the protocol level — access is gated by NetworkPolicy (see below) |
| **Resources** | 4 CPU / 8 Gi memory |
| **Manifests in repo** | `k8s-apps/buildkit/networkpolicy.yaml` (chart values not currently checked in) |

Configured via the in-cluster `buildkitd-config` ConfigMap to treat the local registry (and a couple of aliases) as insecure HTTP, so pushes don't need TLS.

### 2. Local container registry

Plain `registry:2` running as a single Deployment. Used as the push target for buildkitd output and as the pull source for in-cluster Deployments.

| | |
|---|---|
| **Deployment** | `registry` (image `registry:2`) |
| **Namespace** | `registry` |
| **In-cluster URL** | `registry.registry.svc.cluster.local:5000` (HTTP, insecure) |
| **NodePort URL** | `192.168.0.10:30500` (HTTP, insecure) |

Both URLs (plus the short alias `registry:5000`) are in `buildkitd-config` as insecure registries, so `buildctl ... --output ...,push=true` works without TLS.

---

## Network Gating — the gotcha

Access to buildkitd is restricted by a NetworkPolicy enforced by Cilium:

**File:** `k8s-apps/buildkit/networkpolicy.yaml` → `NetworkPolicy/buildkitd-allowlist`

Only pods in these namespaces can reach `buildkitd:1234`:

- `huddle`
- `huddle-test`
- `woodpecker`

Pods in any other namespace will see TCP connect timeouts when they try to dial buildkitd. **This is the most common cause of "the agent thinks it can't build containers."** The agent is correct — the policy is blocking it.

To onboard a new namespace, add a `namespaceSelector` entry in `networkpolicy.yaml` and re-apply:

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: <new-namespace>
      # ...existing entries...
```

```bash
kubectl --as=$KUBECTL_AS apply -f k8s-apps/buildkit/networkpolicy.yaml
```

Verify from inside the target namespace:

```bash
kubectl -n <ns> run bk-test --rm -i --restart=Never \
  --image=moby/buildkit:v0.28.1 -- \
  buildctl --addr tcp://buildkitd.buildkit.svc.cluster.local:1234 debug workers
```

A successful response (a list of workers) confirms the policy is open. A timeout means the policy didn't take effect (or the wrong namespace label is being matched — Cilium uses the standard `kubernetes.io/metadata.name` label that kube-apiserver auto-applies).

---

## How an agent or pipeline builds an image

Minimum viable build-and-push from any allowlisted pod:

```bash
buildctl \
  --addr tcp://buildkitd.buildkit.svc.cluster.local:1234 \
  build \
    --frontend dockerfile.v0 \
    --local context=. \
    --local dockerfile=. \
    --output type=image,name=registry.registry.svc.cluster.local:5000/<repo>:<tag>,push=true
```

No Docker daemon, no root, no privileged container required. The pod only needs:

1. The `buildctl` binary (the `moby/buildkit` image ships with it; CI images bundle it).
2. Network egress to `buildkitd.buildkit.svc.cluster.local:1234` (allowlist gate).
3. Network egress to `registry.registry.svc.cluster.local:5000` (default cluster networking; no extra policy required).

To pull the resulting image elsewhere in the cluster, reference it as `registry.registry.svc.cluster.local:5000/<repo>:<tag>` in the Deployment's `spec.template.spec.containers[].image`.

---

## Reference: who currently uses this

- **Woodpecker CI** (`woodpecker` ns) — builds `huddle` images on push, then runs `helm upgrade` via the `huddle-deployer` ServiceAccount + sealed kubeconfig in `k8s-apps/woodpecker/`.
- **Huddle agents** (`huddle`, `huddle-test`) — builds during development sessions.
