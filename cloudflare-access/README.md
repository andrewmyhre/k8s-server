# Cloudflare Access — Homelab Auth

Authentication for all homelab services is handled by Cloudflare Access (Zero Trust).
No additional k8s deployment needed — auth is enforced at the CF edge before traffic reaches the tunnel.

## How It Works

```
Browser → CF Edge → Access policy check → CF Tunnel → nginx Ingress → Service
                         ↓ if no session
               andrewmyhre.cloudflareaccess.com
                         ↓ OTP to email / Google login
                     CF JWT cookie set
```

## Protected Applications

| Application | URL | CF App ID |
|-------------|-----|-----------|
| Argo Workflows | https://argo-workflows.immutablesoftware.dev | f8943adb-eaa5-432d-9381-0ff455bdbd62 |
| Grafana | https://grafana.immutablesoftware.dev | e8e7f4bf-4088-4e65-999a-3c923dd4ca45 |

## Policy

- **Decision**: Allow
- **Condition**: Email = `andrew.myhre@gmail.com`
- **Session duration**: 24 hours
- **Auth methods**: One-time PIN (email) — no OAuth app needed

## Managing Access

All configuration is in the Cloudflare Zero Trust dashboard:
https://one.dash.cloudflare.com/

To add a new protected service:
1. Create a new Access Application (type: self-hosted)
2. Set domain to the hostname (must be routed through the Cloudflare Tunnel)
3. Add an Allow policy with the email condition

To add a new allowed user:
1. Go to Access → Applications → select app → Policies
2. Edit the policy and add an additional email rule

## Adding to a New Ingress

No nginx ingress changes needed — protection is applied at the CF tunnel level per-hostname,
not at the ingress level. Any hostname added to the CF Tunnel with an Access application
is automatically protected.

## Argo Workflows Auth Mode

Argo runs with `--auth-mode` not set (defaults to `client,server`). Since CF Access protects
the perimeter, the Argo UI is accessible without a service account token — this is intentional
for homelab use. The `server` fallback is the desired behavior once CF Access validates the session.
