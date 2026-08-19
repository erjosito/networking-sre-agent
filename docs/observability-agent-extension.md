# Azure Copilot Observability Agent extension

This optional extension adds an application-facing observability story to the
networking lab. It deliberately does not replace the Azure SRE Agent. Both agents
consume overlapping evidence, but they optimize for different operational jobs.

## SRE Agent versus Observability Agent

| Question | Azure SRE Agent | Azure Copilot Observability Agent |
|---|---|---|
| Primary job | Own an incident workflow for a managed environment | Reduce telemetry and alert noise into an explained application issue |
| Starting point | Azure Monitor alert routed through a response plan | Application Insights chat, alert, issue, or autonomous correlation |
| Persistent context | Knowledge files, skills, custom agents, response plans | Application/dependency topology and concise custom instructions |
| Best evidence | Azure resources, topology, runbooks, CLI diagnostics, domain knowledge | Requests, dependencies, exceptions, traces, metrics, logs, alerts, and changes |
| Action model | Can execute approved or autonomous remediation with configured write access | Investigates and recommends; humans make changes |
| Strongest demo | Diagnose and repair a specific UDR, NVA, DNS, VPN, or FRR fault | Explain blast radius and likely cause across many symptoms and alerts |

The fact that both can investigate an incident is intentional. The useful boundary
is not "network incident versus application incident":

- Use the **Observability Agent first** when the hard problem is determining whether
  many alerts and symptoms are one issue, identifying the affected application
  dependencies, measuring blast radius, or ruling out alternative causes.
- Use the **SRE Agent first** when the incident is already classified as a networking
  problem and the hard problem is interrogating environment-specific topology,
  following a deterministic runbook, or safely changing the environment.

The best combined workflow is:

1. The Observability Agent correlates failed requests, failed dependencies,
   Connection Monitor alerts, and infrastructure telemetry into one issue.
2. Its investigation identifies the failing dependency and likely infrastructure
   layer.
3. The networking SRE Agent receives or is asked to handle the network-specific
   incident, uses the lab knowledge and skills, and proposes or performs remediation.

## Incidents that favor the Observability Agent

These scenarios are better Observability Agent targets than standalone SRE Agent
targets because the core challenge is telemetry synthesis rather than actuation:

1. **Alert storms from one failure.** A DNS or routing fault produces request,
   dependency, availability, Connection Monitor, gateway, and device alerts. The
   desired result is one issue with an explanation of why the alerts belong together.
2. **Unknown blast radius.** Several services share infrastructure, but only one
   dependency or region is failing. Application topology and request telemetry reveal
   which user journeys are affected.
3. **Regression attribution.** Latency rises after a deployment or configuration
   change. The investigation must correlate timing across application telemetry,
   host metrics, Activity Log, and release annotations.
4. **Intermittent or performance failures.** DNS latency, packet loss, or NVA pressure
   causes slow requests before a hard outage. Trends and distributed telemetry matter
   more than a deterministic point-in-time configuration check.
5. **Competing hypotheses.** A storage dependency fails and DNS, identity, compute,
   throttling, and network paths are all plausible. The desired output explicitly
   rules out unsupported hypotheses with evidence.
6. **Observability failures.** Telemetry disappears while the application remains
   healthy. The agent should distinguish a collector blind spot from a service outage.

Pure faults such as "this route table has the wrong next hop" remain stronger SRE
Agent demos because the fault is already localized and remediation is the interesting
part.

## Extension architecture

`scripts/deploy-observability.ps1` deploys:

- `<prefix>-observability-api-ai`: workspace-based Application Insights.
- `<prefix>-observability-api`: Ubuntu VM in the spoke11 default subnet.
- `<prefix>-network-transaction-api`: Flask API instrumented with the Azure Monitor
  OpenTelemetry distribution.
- A synthetic transaction every 15 seconds checking:
  - Private Endpoint DNS returns a private address.
  - Optionally, Private Endpoint HTTPS succeeds when a test page can be published.
  - Cross-hub HTTP to spoke21 succeeds.
  - The optional on-prem HTTP server succeeds when the device extension is present.
- Failed-request, failed-dependency, dependency-latency, and application-exception
  log alerts.
- An Azure Monitor workspace and `Microsoft.Monitor/observabilityAgents` resource in
  a region that supports autonomous operations.
- Subscription-scoped Monitoring Contributor for the agent identity, as recommended
  by Microsoft for reading alerts and telemetry and creating Azure Monitor issues.

The extension is independent of `infra/main.bicep`, so it can be added to an existing
lab without recreating VMs or VPN gateways.

## Deploy

Deploy the base lab first. The on-prem dependency is included automatically when the
optional on-prem server exists.

```powershell
.\scripts\deploy.ps1
.\scripts\deploy-onprem.ps1 -Stage all
.\scripts\deploy-observability.ps1 -ObservabilityLocation canadacentral
```

The base lab can remain in `eastus2`; the Observability Agent and its Azure Monitor
workspace use a separate supported autonomous-operations region.

The dependency-latency profile delays `cross_hub_http` by 3000 ms by default and
alerts at 2000 ms. Both are deployment-time settings:

```powershell
.\scripts\deploy-observability.ps1 `
  -DependencyLatencyTarget cross_hub_http `
  -DependencyLatencyMs 3000 `
  -DependencyLatencyAlertThresholdMs 2000
```

## Initial demos

For a recording-oriented end-to-end run:

```powershell
.\scripts\demo-observability.ps1 -PresenterMode
```

The script restores a clean baseline, records existing issues, runs the selected
scenario, watches the API/telemetry/alert/issue cascade, displays any new issue,
resets or reverts the scenario, and verifies the baseline user transaction. Missing
delayed telemetry, alerts, or a preview agent-created issue are warnings after
cleanup unless `-StrictVerification` is set; scenario behavior or recovery failures
still exit nonzero.

| Scenario | Command | Expected boundary | Infrastructure mutation |
|---|---|---|---|
| DNS split-brain (default) | `.\scripts\demo-observability.ps1 -Scenario dns-split-brain` | `private_endpoint_dns` fails; cross-hub and other dependencies stay healthy | Yes; `pe-dns-override`, always reverted unless `-NoRevert` |
| Dependency latency | `.\scripts\demo-observability.ps1 -Scenario dependency-latency` | `cross_hub_http` is slow; every dependency and the request still succeed | None |
| Application exception | `.\scripts\demo-observability.ps1 -Scenario application-exception` | Every dependency succeeds; the application records an exception and returns a structured 503 | None |

Presenter options can be combined:

| Option | Behavior |
|--------|----------|
| `-PresenterMode` | Enables detailed presenter hints, interactive pauses, and the event timeline. |
| `-PresenterHints` | Prints talking points and exact Portal navigation paths without adding pauses. |
| `-InvestigationStart AlertId` | Prints an exact investigation prompt containing the observed alert ID. This is the default presenter branch. |
| `-InvestigationStart PortalContext` | Prints the equivalent prompt for an alert/Application Insights view already open in the portal. |
| `-SreHandoff` | Prints the exact evidence-and-localized-layer handoff prompt for the networking SRE Agent before recovery. |
| `-OpenPortal` | Opens each suggested Azure resource once in the default browser. |
| `-Interactive` | Pauses before fault injection and recovery without printing the detailed hints. |
| `-Timeline` | Prints relative timestamps for the observed signal cascade. |
| `-PreflightOnly` | Restores and verifies the baseline without injecting the fault. |
| `-StrictVerification` | Also exits nonzero when telemetry, alerts, or issue creation are not observed. Useful for automated validation. |

At each transaction stage, the script prints the exact command executed inside the
private API VM and displays its JSON body plus HTTP status:

```bash
curl --silent --show-error --max-time 30 \
  --header 'X-Lab-Scenario: dependency-latency' \
  --header 'X-Lab-Profile: dependency-latency' \
  --write-out '\nHTTP_STATUS=%{http_code}\n' \
  http://127.0.0.1:8080/api/transaction
```

For a fully guided recording that also opens the relevant resources:

```powershell
.\scripts\demo-observability.ps1 -PresenterMode -OpenPortal
```

### Investigation prompt cards

Presenter hints include copy-ready prompt cards for:

1. Findings: user impact, failed signal, healthy signals, localized layer, and confidence.
2. Evidence: timestamps, resources/dependencies, observed values, and what each proves.
3. Hypotheses ruled out: explicit counter-evidence and unresolved alternatives.
4. Remediation: safest action, risk, rollback, and post-change transaction.
5. Recurrence: comparable historical patterns without counting the current lab run twice.
6. Related alerts: same resource/operation/time-window signals that belong in one
   issue, excluding unrelated profiles and prefixes.

One fault can intentionally create multiple alert instances. The goal is not to make
each alert a separate incident; it is to correlate the same-window request,
dependency, latency, and exception evidence into one Azure Monitor issue. The
Observability Agent instructions enforce that boundary.

The presenter closes with an on-call sequence:
**shift start -> investigate -> document -> verify -> handoff**. This makes the demo
an operational workflow rather than a single chat interaction.

### DNS split-brain

```powershell
.\scripts\inject-fault.ps1 -Scenario pe-dns-override
```

The API treats resolution to a public address as a failed private dependency even if
the public endpoint remains reachable. This produces an application symptom while
unrelated cross-hub and on-prem dependencies can remain healthy.

The HTTPS content check is disabled by default because subscriptions that enforce
`publicNetworkAccess=Disabled` cannot publish the test blob through a `web` Private
Endpoint. DNS validation remains deterministic and is sufficient for this scenario.

### Cross-hub or NVA failure

Inject a UDR, peering, NVA forwarding, or NSG fault. The failed dependency identifies
the affected path, while the successful checks show the blast-radius boundary.

### VPN/on-prem failure

With the on-prem device stage deployed, VPN or FRR faults fail the on-prem dependency
without necessarily affecting the Azure-only dependencies.

## Combined Observability-to-SRE workflow

Run the network scenario with the handoff card:

```powershell
.\scripts\demo-observability.ps1 `
  -Scenario dns-split-brain `
  -PresenterHints `
  -SreHandoff
```

The card summarizes the application evidence, affected and healthy dependencies,
and localized layer, then asks the SRE Agent to diagnose and safely remediate only
that layer. It also requires a support-escalation package when remediation is unsafe
or fails. The demo then reverts the controlled fault when needed and verifies the
same user transaction with `X-Lab-Profile: baseline`.

## Preview considerations

- Autonomous operations are scoped through Application Insights and require a
  `Microsoft.Monitor/observabilityAgents` resource.
- Issue creation also requires the subscription's default Azure Monitor workspace
  association. The deployment script creates it without replacing an existing
  association.
- The agent creates issues and recommendations but does not remediate resources.
- Automatic deep investigation is billable.
- The resource uses preview API `2026-05-01-preview`; provider availability and
  supported regions should be checked before deployment.
- During live validation on August 18, 2026, the preview service accepted the agent,
  monitored resource, workspace association, and recommended RBAC, and fresh alerts
  fired successfully, but no autonomous issue appeared within 25 minutes. Treat
  issue creation as a preview-service readiness gate and verify it before recording.
