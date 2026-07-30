# Documentation

Human-facing documentation for the on-premises extension of the Azure Networking
SRE Agent testbed. (Agent-facing knowledge lives in [`../knowledge/`](../knowledge);
operational notes for this repo live in [`../.github/skills/sre-agent/SKILL.md`](../.github/skills/sre-agent/SKILL.md).)

## Reading order

If you're new to the on-prem extension, read these in order:

1. **[On-prem simulation & telemetry — design & decisions](./onprem-network-simulation-and-telemetry.md)**
   *Why* we simulate on-prem devices the way we do and *how* we get their telemetry
   to Azure Monitor. Covers the options considered (soft router, Containerlab, vendor
   NOS, emulators, mock), the telemetry approaches (syslog, SNMP metrics, RADIUS AAA),
   the data-plane-vs-control-plane detection strategy, fault injection, and the phased
   plan. Start here for the rationale and the big picture.

2. **[On-prem telemetry pipelines — how it works](./onprem-telemetry-pipelines-how-it-works.md)**
   The *implementation* companion: end-to-end wiring of the three telemetry pipelines
   (syslog → Log Analytics, SNMP → Azure Monitor Metrics, RADIUS AAA → Log Analytics),
   with device/collector/Azure config for each, cross-cutting concepts (DCR vs DCE,
   logs vs metrics, alerting), the file map, and a deploy-and-verify walkthrough.

3. **[Containerlab on-prem fabric — how it works](./containerlab-onprem-how-it-works.md)**
   The high-fidelity multi-router fabric: the topology definition, how the veth
   wiring looks on the host, FRR + eBGP config, a control-plane fault demo, and how
   the fabric is wired into the Azure data path (T3 / DNAT) so Connection Monitor can
   traverse it.

4. **[SRE Agent configuration — how it works](./sre-agent-configuration.md)**
   How the deployed SRE Agent *resource* becomes a **working** agent: the two config
   planes (programmatic ARM + data-plane vs. portal-only), the incident **detection**
   model (1-minute Alerts-API scan), the detect → investigate → root-cause → fix
   requirements, how `configure-sre-agent.ps1 -Apply` applies it, and the remaining
   portal-only step (incident response plan).

5. **[How the SRE Agent consumes on-prem telemetry & closes the loop](./sre-agent-telemetry-and-actuation.md)**
   What the agent *does* with the telemetry: the read path (KQL/metrics enrichment,
   RBAC), and how remediation *actuation* on legacy devices would work via an in-VNet
   executor + RADIUS authN/authZ, including the identity/credential model
   (managed identity / WIF vs. long-lived secrets).

## At a glance

| Doc | Type | Answers |
|-----|------|---------|
| [onprem-network-simulation-and-telemetry](./onprem-network-simulation-and-telemetry.md) | Design / decisions | Which simulation & telemetry approach, and why? |
| [onprem-telemetry-pipelines-how-it-works](./onprem-telemetry-pipelines-how-it-works.md) | Implementation | How does telemetry actually reach Azure Monitor? |
| [containerlab-onprem-how-it-works](./containerlab-onprem-how-it-works.md) | Implementation | How is the multi-router fabric built & wired in? |
| [sre-agent-configuration](./sre-agent-configuration.md) | Implementation | How is the agent configured to detect & fix? |
| [sre-agent-telemetry-and-actuation](./sre-agent-telemetry-and-actuation.md) | Concept / design | How does the agent read telemetry & act on devices? |

## Related material outside `docs/`

- [`../README.md`](../README.md) — repository overview, quick start, fault catalog.
- [`../knowledge/`](../knowledge) — knowledge base uploaded to the agent (incl.
  `onprem-network-topology`, `onprem-ospf-fault-runbook`, `onprem-bgp-fault-runbook`,
  `onprem-telemetry-and-observability`).
- [`../infra/containerlab/README.md`](../infra/containerlab/README.md) — containerlab
  quick reference.
- [`../.github/skills/sre-agent/SKILL.md`](../.github/skills/sre-agent/SKILL.md) —
  operational playbook for working in this repo.
