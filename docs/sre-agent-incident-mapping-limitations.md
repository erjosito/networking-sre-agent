# SRE Agent — Alert→Incident Mapping Limitations (testing findings)

> **📍 Part A — Azure Networking SRE** (agent behavior). See the [docs hub](./README.md).

This document records limitations we hit **in the Azure SRE Agent's logic that maps
fired Azure Monitor alerts onto incidents** (its dedup / merge / correlation behavior),
plus a few adjacent incident-lifecycle limitations observed during testing of this lab.

These are **product observations**, not bugs in this repository — they describe how the
agent behaved against real alerts fired by the lab's Connection Monitors and on-prem
syslog rules, and where that behavior surprised us. Where a workaround exists in this
repo, it is noted.

> **Scope:** findings 1–2 are the two mapping issues that motivated this doc; findings
> 3–6 are related incident-lifecycle limitations we ran into while testing them.

---

## 0. Background — how the agent maps alerts to incidents

The agent does **not** receive incidents via an action group. A scanner **polls the
Azure Monitor Alerts Management API** and turns fired alerts into investigation
threads, deduplicating repeat firings within a time window. The relevant knobs
([Azure Monitor alerts in SRE Agent](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts)):

| Setting | Value |
|---------|-------|
| Scan interval | 1 minute |
| Alerts per API call | 250 |
| Initial scan lookback | 1 day |
| **Merge lookback (dedupe repeated firings)** | **7 days** |
| Status sync interval | 5 minutes |

**The key design fact behind every finding below:** dedup/merge is keyed on the
**alert-rule identity** (plus the 7-day window), *not* on the underlying event, the
monitored resource, or the network topology. That single design choice produces both a
**false-positive merge** (Finding 1) and **false-negative merges** (Finding 2).

Alert rules referenced below (prefix `netsre`, from `infra/modules/onprem-alerts.bicep`
and `infra/modules/onprem-log-alerts.bicep`):

| Rule | Sev | Signal | Fires on |
|------|-----|--------|----------|
| `netsre-clab-cm-test-result-fail` | Sev1 | metric `TestResult` | on-prem fabric unreachable (Connection Monitor) |
| `netsre-clab-cm-checks-failed` | Sev2 | metric `ChecksFailedPercent` | same Connection Monitor, checks-failed % |
| `netsre-onprem-syslog-critical` | Sev1/2 | Log Analytics `Syslog` | FRR `daemon` error/critical (BGP/OSPF adjacency loss) |

---

## 1. Over-merge — distinct occurrences collapse into one stale incident

**What we saw.** Two *separate occurrences* of a Connection Monitor alert were mapped to
the **same incident**, even though they represented different troubleshooting episodes.
A stale, already-**resolved** incident for a given rule **reactivated / absorbed** the
new firing instead of opening a fresh investigation.

**Why it happens.** Within the 7-day merge lookback, any new firing of a rule whose
prior incident still exists (even `resolved`) is treated as a *repeat* of that incident.
The agent has no notion that the earlier incident was already investigated and closed, so
the operator loses the "one incident = one investigation" boundary.

**Impact.**
- New, genuinely distinct events inherit a stale incident's history, mode, and verdict.
- A resolved incident silently reopens, so the fresh firing never gets a clean trajectory.
- Metrics like MTTR/incident-count are distorted (one incident spans multiple events).

**Workaround (this repo).** Delete the stale incident before re-testing so the next
firing creates a clean incident:

```powershell
.\scripts\clear-incidents.ps1 -TitleContains clab -Force      # or -Id <threadId>
```
```bash
./scripts/clear-incidents.sh --title-contains clab --yes
```

---

## 2. Under-merge — one root cause produces multiple uncorrelated incidents

The mirror image of Finding 1: because merging is keyed on *rule identity*, **different
signals describing the same real fault are never correlated into one incident**. We hit
this in two forms.

### 2a. Two metric rules on the *same* Connection Monitor → two incidents

A single fabric fault trips **both** CM alert rules — `netsre-clab-cm-test-result-fail`
(TestResult) **and** `netsre-clab-cm-checks-failed` (ChecksFailedPercent) — on the *same*
`netsre-clab-connection-monitor`. The agent dedups *per rule*, so this opens **two
parallel incidents** for one underlying outage, each investigated independently.

### 2b. A Connection Monitor alert + a BGP-adjacency syslog alert → not deduped

This is the case worth highlighting. One OSPF/BGP fault in the fabric produces, for the
*same* root cause and time window, **two different alerts**:

1. a **data-plane** signal — the clab Connection Monitor fails
   (`netsre-clab-cm-test-result-fail`), because the LAN prefix is withdrawn; and
2. a **control-plane** signal — the FRR router logs a BGP/OSPF **adjacency loss** to
   syslog, firing `netsre-onprem-syslog-critical`.

These are two views of **one incident** (the cascade documented in
[`knowledge/onprem-network-topology.md`](../knowledge/onprem-network-topology.md): OSPF
adjacency down → peer loopback withdrawn → BGP session drops → LAN 172.31.20.0/24
withdrawn → CM fails). A human operator immediately correlates them. The SRE Agent does
**not** — it opens **separate incidents** because the two alerts come from different
rules (and different sources: a metric alert vs a log alert), with no topological or
temporal correlation between them.

**Why it happens.** No cross-rule / cross-signal correlation. The agent lacks a notion of
"these alerts share a monitored resource / topology / blast radius / time window, so
they're one incident." Correlation would require either topology awareness or a
resource/temporal grouping heuristic that spans alert rules.

**Impact.**
- N alerts for one fault = N concurrent investigations, each spending tokens and Azure
  API calls re-deriving the same root cause.
- Investigations can reach **different or partial verdicts** for the same event, and can
  race (we saw one of a pair stall while the other progressed).
- The control-plane syslog (the *cause*) and the data-plane CM failure (the *symptom*)
  are never automatically linked, so the agent may root-cause from the symptom side alone.

**Partial mitigation (this repo).** The response plans give both signals the **same
handler + processing guide** (`network-expert` + the `onprem-fabric-triage` steps in
`sre-agent-config/config.yaml`), so *whichever* incident is worked follows the same
OSPF-first cascade logic and should reach the correct root cause. This does **not**
merge the incidents — it only makes each independent investigation consistent.

> **User's own framing:** "having multiple alerts is more realistic" — the problem is not
> that multiple alerts fire, it's that the agent cannot **fold them into one incident**.
> This is the single most-requested capability we'd expect customers to ask for.

---

## 3. Incident autonomy mode is frozen at creation

**What we saw.** An incident **created while the agent was in Review mode stayed in
Review** even after the agent was switched globally to **Autonomous** — it kept asking
for manual approval. Only *new* incidents created after the switch were Autonomous.

**Impact.** You cannot "promote" an in-flight incident to Autonomous; a long-lived or
reactivated incident (see Finding 1) can be permanently stuck in the old mode.

**Workaround.** Delete the stale incident so the next firing creates a fresh incident in
the current mode (`clear-incidents.ps1` / `.sh`).

---

## 4. No programmatic resolve/close/reassign — only delete

**What we saw.** The only incident-mutation verb the data plane accepts is
**`DELETE /api/v1/threads/{id}`** (HTTP 204). `OPTIONS`, `POST`, `PATCH`, and the
`status`/`resolve` routes we tried all returned **HTTP 405**.

**Impact.** There is no supported API to *resolve*, *close*, *split*, *reassign*, or
*re-open* an incident programmatically — the only lifecycle action is destructive
deletion, which loses the incident's history. This is what forced us to build the
`clear-incidents` scripts to reset state between tests.

---

## 5. UI autonomy toggle has a propagation lag

**What we saw.** After enabling Autonomous mode in the portal, the setting *appeared*
active but the agent **still prompted for action confirmation**; a **browser refresh**
was required before the Autonomous setting actually took effect.

**Impact.** Easy to believe the agent is hands-off when it is still in Review. Verify the
effective mode on a **freshly loaded** page (or via the incident's `agentMode` field on
the data plane) rather than trusting the toggle state in a stale tab.

---

## 6. Response-plan cooldown can suppress legitimate re-tests

**What we saw.** Response plans carry a `cooldownHours` (3–6h in
`sre-agent-config/config.yaml`). During iterative fault testing this can **gate a
legitimately new firing** of the same plan, so a real re-occurrence within the cooldown
window may not open an incident.

**Impact / tuning.** Good for suppressing flapping in production; a foot-gun during
rapid demo/test loops. Lower `cooldownHours` (or delete the prior incident) when
re-testing back-to-back.

---

## Summary

| # | Limitation | Class | Root cause | Workaround in this repo |
|---|------------|-------|-----------|--------------------------|
| 1 | Distinct occurrences merge into a stale/resolved incident | **Over-merge** | Merge keyed on rule identity + 7-day window | Delete stale incident before re-test |
| 2a | Two metric rules on one CM → two incidents | **Under-merge** | Per-rule dedup, no resource grouping | Same handler/guide for both |
| 2b | CM alert + BGP-adjacency syslog → two incidents | **Under-merge** | No cross-signal / topology correlation | Same handler/guide for both |
| 3 | Autonomy mode frozen at incident creation | Lifecycle | Mode captured once, immutable | Delete + let a fresh incident form |
| 4 | Only `DELETE` mutates incidents (405 on the rest) | Lifecycle/API | No resolve/close/reassign API | `clear-incidents` scripts |
| 5 | UI autonomy toggle propagation lag | UX | Stale client state | Refresh; check effective `agentMode` |
| 6 | Response-plan cooldown suppresses re-tests | Config | `cooldownHours` gating | Lower cooldown / delete prior incident |

### What we'd want from the product

- **Topology- / resource-aware incident correlation** so multiple alerts (across rules
  *and* across metric vs. log sources) for one blast radius fold into **one** incident —
  the fix for Findings 2a and 2b.
- **Explicit incident boundaries**: don't reactivate a **resolved** incident for a new
  firing — open a fresh one, or make reactivation opt-in per rule (Finding 1).
- **A full incident-lifecycle API** (resolve / close / split / merge / reassign /
  re-open), not just delete (Finding 4).
- **Mutable per-incident autonomy** so an in-flight incident can be promoted to
  Autonomous (Finding 3).

---

*Companion docs:*
[SRE Agent configuration — how it works](./sre-agent-configuration.md)
· [SRE Agent — consumes telemetry & closes the loop](./sre-agent-telemetry-and-actuation.md)
· [On-prem network topology (the OSPF→BGP→CM cascade)](../knowledge/onprem-network-topology.md)
