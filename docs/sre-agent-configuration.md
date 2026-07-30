# Azure SRE Agent Configuration — How It Works

This document explains what it takes to turn the deployed Azure SRE Agent
**resource** into a **working agent** that closes the incident loop:

> **detect → investigate → identify root cause → (ideally) fix**

It covers the two configuration planes, exactly which pieces are applied
programmatically vs. in the portal, how incident **detection** actually works, the
API surface we use, and how to verify readiness.

> Companion docs: [`onprem-telemetry-pipelines-how-it-works.md`](./onprem-telemetry-pipelines-how-it-works.md)
> (how telemetry reaches Azure Monitor) and the runbooks in [`../knowledge/`](../knowledge)
> (what the agent reads to troubleshoot).

---

## 0. TL;DR

| Question | Answer |
|----------|--------|
| Is deploying `sre-agent.bicep` enough? | **No.** The Bicep deploys only the agent *resource* + RBAC. Behaviour (incident platform, knowledge, response plans) is configured afterwards. |
| How does the agent get alerts? | It **polls the Azure Monitor Alerts API every ~1 min** with its managed identity. No action group points at it. |
| What's applied automatically by `deploy.ps1`? | Azure Monitor incident integration, knowledge-graph scope, and the knowledge base (via `configure-sre-agent.ps1 -Apply`). |
| What still needs the portal? | **Incident response plan(s)** (required to close the loop) + optional sub-agents/skills/connectors. |
| How do I check what's done? | `.\scripts\configure-sre-agent.ps1` prints a **Working-agent readiness** report. |

---

## 1. The two configuration planes

The SRE Agent's configuration is split across two planes. Most of it is now
programmatic; a few objects remain portal-only.

```mermaid
flowchart TB
    subgraph CP["Control plane — ARM (management.azure.com)"]
        direction LR
        R["Agent resource + RBAC<br/>sre-agent.bicep"]
        I["incidentManagementConfiguration.type = AzMonitor<br/>knowledgeGraphConfiguration.managedResources = [rg]<br/>(az rest PATCH, api 2026-01-01)"]
    end
    subgraph DP["Data plane — agent endpoint (*.azuresre.ai)"]
        direction LR
        K["Knowledge base<br/>POST /api/v1/agentmemory/upload"]
        P["Sub-agents · skills · response plans · connectors<br/>(portal sre.azure.com — undocumented API)"]
    end
    B["scripts/configure-sre-agent.ps1 -Apply"] --> I
    B --> K
    deploy["scripts/deploy.ps1"] --> R
    deploy --> B
    portal["Operator in sre.azure.com"] --> P
```

### Control plane — ARM, GA API `2026-01-01`
Set with `az rest` PATCH against the agent resource:

- `incidentManagementConfiguration.type = AzMonitor` — connects Azure Monitor as the
  incident source. **No credentials needed**: alerts flow in via the agent's managed
  identity. (Other values: `PagerDuty`, `ServiceNow`, `None`.)
- `knowledgeGraphConfiguration.managedResources = [ <resource group id> ]` — scopes
  which resources the agent reasons over (and where it looks for alerts). The
  knowledge-graph UAMI (`identity`) is preserved.

### Data plane — agent endpoint `https://<name>.<region>.azuresre.ai`
Token audience **`https://azuresre.dev`** (`az account get-access-token --resource https://azuresre.dev`):

- **Knowledge upload:** `POST /api/v1/agentmemory/upload` — `multipart/form-data`, form
  field name **`files`** (plural, repeatable; ≤16 MB/file, ≤100 MB total).
- **Status:** `GET /api/v1/agentmemory/status` and `GET /api/v1/agentmemory/indexer-status`
  (reports `documentsProcessed` / `documentsFailed`).

### Portal only (`sre.azure.com`)
Custom (sub)agents, skills, **incident response plans**, scheduled tasks, and connectors
(data sources). The data-plane `/api/v2/extendedAgent/{agents,connectors,skills,…}` PUT
envelope is undocumented/portal-SPA-internal, and the ARM `subagents` sub-resource is
gated: *"Agent Extensions are not available for this tenant. This feature is restricted to
internal tenants only."* These must be created in the portal.

---

## 2. What makes a "working" agent

All of the following must hold for a full detect → investigate → root-cause → fix loop.
`configure-sre-agent.ps1` verifies the automatable ones in its **Working-agent readiness**
section.

| Stage | Requirement | Where / how | Automated? |
|-------|-------------|-------------|------------|
| **Detect** | Incident platform = Azure Monitor | `incidentManagementConfiguration.type=AzMonitor` | ✅ `configure-sre-agent.ps1 -Apply` |
| **Detect** | Managed identity has **Monitoring Contributor on the SUBSCRIPTION** | `modules/sre-agent-sub-roles.bicep` | ✅ bicep |
| **Detect** | Alert rules that actually fire | `modules/alerts.bicep` (metric alerts on Connection Monitors) | ✅ bicep |
| **Detect** | Agent scoped to the resources | `knowledgeGraphConfiguration.managedResources=[<rg>]` | ✅ script / bicep |
| **Investigate** | Read telemetry (logs / metrics) | Reader + Log Analytics Reader + Monitoring Reader on RG | ✅ bicep |
| **Investigate** | Run diagnostics (`az`, `az vm run-command`) | Contributor (`accessLevel=High`) | ✅ bicep |
| **Investigate** | Domain context | Knowledge base (17 files) | ✅ `-Apply` (agentmemory) |
| **Root-cause** | Route incident to the right expert | **Incident response plan** | ❌ **portal-only, REQUIRED** |
| **Fix** | Write access | Contributor + Network Contributor | ✅ bicep |
| **Fix** | Autonomy | `mode=Review` (propose + approve) or `Autonomous` (hands-off) — `sreAgentMode` param | ✅ bicep param |

**The single remaining blocker for a closed loop is a portal-only incident response plan.**
Without at least one, the agent still detects incidents and opens investigation threads,
but it won't automatically route them to a custom agent or act.

---

## 3. How detection actually works

The agent does **not** rely on an action group being pointed at it. Instead, a scanner
**polls the Azure Monitor Alerts Management API** on a schedule and turns fired alerts into
investigation threads.

```mermaid
sequenceDiagram
    participant CM as Connection Monitor
    participant AM as Azure Monitor (Alerts)
    participant AG as SRE Agent (scanner)
    participant RP as Response plan
    CM->>AM: probe fails → metric breaches threshold
    AM->>AM: alert rule fires (netsre-*-cm-*)
    loop every ~1 min (managed identity)
        AG->>AM: GET fired alerts in managedResources scope
    end
    AM-->>AG: alert(s)
    AG->>AG: acknowledge + open/merge investigation thread
    AG->>RP: match severity/title?
    RP-->>AG: route to custom agent + autonomy
    AG->>AG: investigate (knowledge + az tools) → root cause → propose/apply fix
```

Scanner facts (from the [Azure Monitor alerts docs](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts)):

| Setting | Value |
|---------|-------|
| Scan interval | 1 minute |
| Alerts per API call | 250 |
| Initial scan lookback | 1 day |
| Merge lookback (dedupe repeated firings) | 7 days |
| Status sync interval | 5 minutes |

If alerts never appear, the docs say to check exactly three things — all satisfied in this
repo and verified by the readiness script:

1. The identity has **Monitoring Contributor on the subscription**
   (`modules/sre-agent-sub-roles.bicep`).
2. Azure Monitor **alert rules exist** for the scoped resources (`modules/alerts.bicep`).
3. The alert rules **actually fired**.

> The action group in `alerts.bicep` (`<prefix>-netops-ag`) only sends operator **email** —
> it is not how the agent receives incidents.

---

## 4. Applying the configuration

### Automatically, during deployment
`deploy.ps1` runs the configurator post-deploy (when `-DeploySreAgent`, non-fatal on error):

```powershell
# inside deploy.ps1, after the infra deployment:
.\scripts\configure-sre-agent.ps1 -AgentName "$Prefix-sre-agent" -ResourceGroup $ResourceGroup -Apply
```

### Manually / to re-check
```powershell
# Report only (read-only): validate manifest + print Working-agent readiness
.\scripts\configure-sre-agent.ps1

# Apply: PATCH AzMonitor + scope, upload + index the knowledge base
.\scripts\configure-sre-agent.ps1 -Apply
```

The script reads the declarative manifest [`sre-agent-config/config.yaml`](../sre-agent-config/config.yaml)
(agent name/RG, the 17 `knowledge:` files, custom agents, skills, response plans, scheduled
tasks). It requires **Python + PyYAML** to parse the manifest.

### The remaining portal step (required): incident response plan
In `sre.azure.com` → **Builder → Incident response plans**, create at least one plan that maps
**severity / title → custom agent → autonomy**. The manifest declares two
(`connectivity-failure`, `latency-degradation`) you can mirror. Docs:
<https://learn.microsoft.com/azure/sre-agent/incident-response-plans>.

Optional portal steps that improve investigation quality: create the custom **sub-agents**
(`network-expert`, `connectivity-triage`), add **skills**, and add **connectors** (data
sources such as Azure Monitor logs). For hands-off remediation, deploy with
`-sreAgentMode Autonomous` (default is `Review` = propose + wait for approval).

---

## 5. Known caveats

- **Portal "incident platform" panel may show "not connected"** even though
  `incidentManagementConfiguration.type=AzMonitor` is set and confirmed via ARM GET. The
  portal appears to wire additional data-plane state when you click **Connect**. Alert
  scanning via `managedResources` still works; complete the portal Connect step if the
  panel matters to you.
- **Sub-agents / skills / response plans / connectors are portal-only** in this tenant
  (undocumented data-plane envelope; ARM `subagents` gated to internal tenants). They cannot
  currently be scripted end-to-end from here.
- **Windows CLI quoting:** `az ... --query "length([?x])"` can lose its quotes on Windows;
  the readiness check parses JSON in PowerShell instead. KQL string literals passed to
  `az monitor log-analytics query` must use **single** quotes.

---

## 6. References

- Azure Monitor alerts in SRE Agent — <https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts>
- Incident response plans — <https://learn.microsoft.com/azure/sre-agent/incident-response-plans>
- Incident platforms — <https://learn.microsoft.com/azure/sre-agent/incident-platforms>
- Connectors (data sources) — <https://learn.microsoft.com/azure/sre-agent/connectors>
- Repo pieces: `infra/modules/sre-agent.bicep`, `infra/modules/sre-agent-sub-roles.bicep`,
  `infra/modules/alerts.bicep`, `scripts/configure-sre-agent.ps1`, `scripts/deploy.ps1`,
  `sre-agent-config/config.yaml`.

---

*Companion docs:*
[SRE Agent — consumes telemetry & closes the loop](./sre-agent-telemetry-and-actuation.md)
· [Telemetry pipelines — how it works](./onprem-telemetry-pipelines-how-it-works.md)
· [On-prem simulation & telemetry (design/decisions)](./onprem-network-simulation-and-telemetry.md)
