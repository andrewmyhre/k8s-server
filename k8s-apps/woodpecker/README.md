# Woodpecker CI

Self-hosted CI/CD orchestrator. Already installed into this cluster via Helm
(release `woodpecker`, namespace `woodpecker`, chart `woodpecker-ci/woodpecker`,
version v3.13.0). Reachable at:

- **External (Cloudflare Access):** https://woodpecker.primera.rodeo
- **In-cluster:** `woodpecker-server.woodpecker.svc.cluster.local:80`
- **gRPC (agent → server):** `woodpecker-server.woodpecker.svc.cluster.local:9000`

GitHub OAuth is wired via the `woodpecker-github-oauth` secret (see below).
Admin user: `andrewmyhre`.

Other projects already using this instance: `andrewmyhre/ai-services` (AWS CDK
deploys). The pipelines for that repo live at `/projects/ai-services/.woodpecker/`
and are a useful reference.

## What lives in this folder

| File | Purpose |
|------|---------|
| `huddle-deployer-rbac.yaml` | ServiceAccount `huddle-deployer` + long-lived token Secret + `cluster-admin` ClusterRoleBinding. Used by the huddle `.woodpecker/build-deploy.yml` pipeline to run `helm upgrade` against the `huddle` namespace. |
| `huddle-deployer-kubeconfig-sealed.yaml` | SealedSecret that materializes `Secret/woodpecker-huddle-kubeconfig` in the `woodpecker` namespace. The pipeline mounts this as `/root/.kube/config`. |
| `README.md` | This file. |

The Helm release itself is not tracked in this repo — it was installed
interactively by the user. Configuration (GitHub OAuth, admin user) is stored
in-cluster in the `woodpecker-github-oauth` secret.

## Why cluster-admin for the huddle deployer?

The huddle Helm chart (`/projects/huddle/infra/helm/huddle/`) currently renders:
- A cluster-scoped `PersistentVolume` (`templates/data-pv.yaml`)
- `ClusterRole`s and `ClusterRoleBinding`s with `escalate` / `bind` verbs
  (`templates/agent-rbac.yaml`)

Namespace-admin would fail on both. Once the PV is split out of the chart
(planned follow-up — the "PV migration" the CI pipeline is meant to drive), this
ClusterRoleBinding can be narrowed to a focused ClusterRole + per-namespace
RoleBinding. The narrowing is an explicit to-do on this infrastructure.

## Adding / rotating the kubeconfig secret

The SA token does NOT auto-rotate (it's a legacy long-lived token). Rotate by
deleting and recreating the `huddle-deployer-token` Secret — the controller
will mint a new token within seconds — then regenerate the kubeconfig and
re-seal:

```bash
# Rotate SA token
kubectl -n woodpecker delete secret huddle-deployer-token
kubectl apply -f huddle-deployer-rbac.yaml   # recreates Secret, controller repopulates it
sleep 3

# Rebuild kubeconfig
TOKEN=$(kubectl -n woodpecker get secret huddle-deployer-token -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl -n woodpecker get secret huddle-deployer-token -o jsonpath='{.data.ca\.crt}')
TMP=$(mktemp -d)
cat > "$TMP/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: sleeper-service
    cluster:
      server: https://kubernetes.default.svc.cluster.local
      certificate-authority-data: ${CA}
users:
  - name: huddle-deployer
    user:
      token: ${TOKEN}
contexts:
  - name: huddle-deployer@sleeper-service
    context:
      cluster: sleeper-service
      user: huddle-deployer
      namespace: huddle
current-context: huddle-deployer@sleeper-service
EOF

kubectl -n woodpecker create secret generic woodpecker-huddle-kubeconfig \
  --from-file=config="$TMP/kubeconfig" \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace=kube-system --controller-name=sealed-secrets-controller \
      --format=yaml \
      > huddle-deployer-kubeconfig-sealed.yaml

rm -rf "$TMP"
kubectl apply -f huddle-deployer-kubeconfig-sealed.yaml
```

The plaintext file never leaves `$TMP` (auto-cleaned by the trap). Commit the
updated `huddle-deployer-kubeconfig-sealed.yaml` to this repo.

## Related changes

- `k8s-apps/buildkit/networkpolicy.yaml` was updated in the same PR to allow
  the `woodpecker` namespace as an additional ingress source (previously only
  `huddle` and `huddle-test`).
