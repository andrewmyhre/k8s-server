# Daily Digest System

The homelab runs two complementary daily notification systems: the **PAI Daily Plan** (AI-generated project digest) and **Grafana Alerting** (real-time infrastructure alerts). This document covers both.

---

## 1. PAI Daily Plan

### What It Does

Every weekday at 6:30 AM Eastern, an Argo Workflow:

1. Discovers all registered project modules
2. Runs each module in parallel — each calls the Claude API with project-specific context
3. Assembles the section outputs (sorted by order) into a single Markdown document
4. Converts to HTML and emails it via AWS SES to `andrew.myhre@gmail.com`
5. Saves the assembled plan to `/projects/DAY-PLAN.md` on the cluster

### Architecture

**Orchestrator:** Argo Workflows (`CronWorkflow` in the `pai` namespace)  
**Schedule:** `30 6 * * 1-5` (America/New_York), concurrency policy: Forbid  
**Manifests:** `/projects/homelab/k8s-apps/pai/`  
**Feature branches:** `feat/pai-daily-workflow`, `feat/pai-extend-daily-sections`

#### Workflow DAG

```
image-refresh
    └── init-workspace
            └── discover-steps
                    └── run-project-steps (parallel fan-out, one per module)
                                └── aggregate-and-email
```

| Step | What it does |
|---|---|
| `image-refresh` | Builds a Docker image via Kaniko (Python + AWS CLI + kubectl + Node 22) and pushes to the local registry at `192.168.0.10:30500` |
| `init-workspace` | Cleans `/tmp/pai-daily/sections/` to start fresh |
| `discover-steps` | Queries WorkflowTemplates labelled `pai.io/workflow=daily-plan` and returns a JSON list of template names |
| `run-project-steps` | Fan-out: spawns one child workflow per template, each running `pai-module-runner.py` against a project's `.daily/prompt.md` |
| `aggregate-and-email` | Concatenates section files in filename order, generates HTML, sends via SES |

### Project Module System

Each project opts into the digest by having a `.daily/prompt.md` file with YAML frontmatter:

```yaml
---
name: "Project Name"
order: 010          # Controls sort order in the assembled email (lower = earlier)
active: true        # Set false to skip this module entirely
schedule: weekdays  # Options: always | weekdays | monday,tuesday,... (comma list)
expires: 2026-12-31 # Optional — module is skipped after this date
---

## Output Format
[Describe the Markdown structure you want Claude to produce]

## Data Sources
- `/projects/project-name/docs/some-file.md`
- `~/.daily/status.md`

## Commands
- `kubectl get pods -A`
- `some-other-cli-command`
```

The runner (`pai-module-runner.py`, embedded in the `pai-runner-dockerfile` ConfigMap) does:

1. Parses YAML frontmatter
2. Evaluates `active`, `schedule`, and `expires` — skips silently if any fail
3. Reads every file listed under **Data Sources**
4. Executes every command listed under **Commands** and captures stdout
5. Calls the Claude Sonnet API with all context + the prompt body
6. Writes output to `/tmp/pai-daily/sections/<order>-<slug>.md`

### Registered Modules (WorkflowTemplates)

| Template name | Project |
|---|---|
| `daily-plan-step-aws-account` | AWS account status |
| `daily-plan-step-civics` | Civics project |
| `daily-plan-step-donk` | Donk project |
| `daily-plan-step-home` | Home project |
| `daily-plan-step-job-search` | Job search |
| `daily-plan-step-travel` | Travel |
| `daily-plan-step-wellness` | Wellness |
| `daily-plan-step-k8s-server` | Cluster health |

### Email Delivery

| Field | Value |
|---|---|
| Provider | AWS SES (`us-east-1`) |
| From | `rik@immutablesoftware.dev` |
| To | `andrew.myhre@gmail.com` |
| Subject | `Day Plan — [Date]` |
| Format | HTML with GitHub-like CSS styling |

### Kubernetes Resources

| File | Purpose |
|---|---|
| `k8s-apps/pai/namespace.yaml` | Creates the `pai` namespace |
| `k8s-apps/pai/rbac.yaml` | `pai-workflow-runner` ServiceAccount + Role; `pai-cluster-reader` ClusterRole for cross-namespace health checks |
| `k8s-apps/pai/configmaps.yaml` | `pai-runner-dockerfile` (Dockerfile + `pai-module-runner.py` + `send_ses.py`); `pai-ses-helper` |
| `k8s-apps/pai/daily.yaml` | The `CronWorkflow` definition |
| `k8s-apps/pai/workflowtemplates.yaml` | One `WorkflowTemplate` per project module |
| `k8s-apps/pai/sealedsecrets.yaml` | `pai-aws-credentials`, `pai-claude-api-key`, `pai-resend-api-key` |

---

## 2. Grafana Alerting

### What It Does

Continuous monitoring of Prometheus metrics. When a threshold is breached, Grafana fires an alert to both Slack and email.

**Contact point:** "All Alerts" → `#automation` (Slack) + `andrew.myhre@gmail.com`  
**Repeat interval:** 4 hours  

### Alert Rules (`k8s-apps/monitoring/grafana-alert-rules.yaml`)

| Alert | Condition |
|---|---|
| `disk-usage-high` | >85% disk usage for 5 minutes |
| `cilium-agent-crashloop` | >3 container restarts in 10 minutes |

### Email Delivery

| Field | Value |
|---|---|
| Provider | AWS SES via SMTP (`email-smtp.us-east-1.amazonaws.com:587`) |
| From | `alerts@immutablesoftware.dev` |
| Credentials | `k8s-apps/monitoring/grafana-alerting-sealed.yaml` (SealedSecret) |

---

## 3. Adding a New Project to the Daily Digest

1. Create `.daily/prompt.md` in the project root with appropriate frontmatter (`name`, `order`, `active`, `schedule`).
2. Add a new `WorkflowTemplate` to `k8s-apps/pai/workflowtemplates.yaml` labelled `pai.io/workflow: daily-plan` that invokes `pai-module-runner.py` with the project path.
3. Apply the updated manifest: `kubectl apply -f k8s-apps/pai/workflowtemplates.yaml`.

The next scheduled run will automatically discover and include the new module.

---

## Key File Locations

| Path | Description |
|---|---|
| `/projects/homelab/k8s-apps/pai/` | All PAI system Kubernetes manifests |
| `/projects/homelab/k8s-apps/monitoring/grafana-alert*.yaml` | Grafana alerting rules and sealed credentials |
| `/projects/<project>/.daily/prompt.md` | Per-project module definition |
| `/projects/DAY-PLAN.md` | Last assembled day plan (written by the workflow) |
| `/projects/homelab/.daily/systemd-pending.txt` | Host-level systemd pending-upgrade cache |
