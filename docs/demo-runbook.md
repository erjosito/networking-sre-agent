# SRE Agent — Live Demo Runbook (for video recording)

> **📍 Part A — Azure Networking SRE.** A repeatable, on-camera demo of the Azure SRE
> Agent detecting → investigating → root-causing → fixing a networking fault.
> Driver script: [`scripts/demo.ps1`](../scripts/demo.ps1). See the [docs hub](./README.md).

Two takes are provided, both driven by the same one command:

| Take | Command | Fault | The story |
|------|---------|-------|-----------|
| **A — Azure** | `.\scripts\demo.ps1 -Scenario azure -Interactive` | `udr-wrong-nexthop` | A spoke's default route next-hop is repointed to an unreachable IP — the classic *"next-hop off by one"* black-hole. Every resource still looks healthy; only the Connection Monitors fail. |
| **B — On-prem fabric** | `.\scripts\demo.ps1 -Scenario clab -Interactive` | `clab-ospf-area-mismatch` | An OSPF area mismatch on the containerlab fabric drops the adjacency, withdraws the peer loopback, tears down BGP-over-loopback, and withdraws the LAN — a **control-plane cascade** the agent must unwind OSPF-first. |

Each take runs the same four phases: **clear → inject → watch → revert.**

---

## 0. Why these two faults

They are the flagship examples from the [*why networking SRE is different*](../README.md#why-networking-sre-is-a-different-and-harder-problem)
narrative: the **symptom is identical** ("can't reach X", Connection Monitor fails) but the
**root cause hides in a different layer** each time (an Azure UDR vs. an on-prem OSPF
adjacency). They show the agent doing the expensive part — multi-layer correlation — in
minutes instead of hours.

---

## 1. Pre-flight checklist (before you hit record)

> **The demo script now automates most of this in Step 0.** `demo.ps1` (unless you pass
> `-SkipPreflight`) verifies `az login`, **starts the scenario's Connection-Monitor source VMs**
> if they are deallocated, and for the clab take **rebuilds the fabric + host-probe wiring** if the
> host→LAN probe is broken. Run `.\scripts\demo.ps1 -Scenario clab -PreflightOnly` to warm and
> verify the lab ahead of time. The items below are what the script does *for* you (✅) versus what
> still needs your eyes (⚠️).

- ✅ **VMs started.** Step 0 starts the source VMs for the take (spoke11 VM for Azure;
  `netsre-onprem-clab` for clab) and waits until they report *running* — deallocated VMs report
  *Unknown*, not pass/fail.
- ✅ **clab fabric + host-probe wiring.** The `clabr1host` veth IP and LAN route (and the FRR
  container fabric) are not durable across a VM stop/start; Step 0 probes `172.31.20.10` and, if it
  fails, runs the idempotent on-VM helper `/usr/local/bin/onprem-clab-up.sh` to rebuild both. If you
  ever need to do it by hand:
  ```bash
  ip addr replace 172.31.11.1/30 dev clabr1host
  ip link set dev clabr1host up
  ip route replace 172.31.20.0/24 via 172.31.11.2 dev clabr1host
  # verify: ping -c3 172.31.20.10  → 0% loss
  ```
- ✅ **No stuck/stale incidents.** Step 1 (`clear-incidents.ps1 -Force`) deletes prior incidents so
  the new alert opens a *fresh* one. Pre-check with `.\scripts\clear-incidents.ps1 -ListOnly`.
- ⚠️ **Agent in Autonomous mode** so it *acts* on-camera, not just proposes. Verify on a
  **freshly loaded** portal page (the toggle has a propagation lag — see the
  [mapping-limitations doc](./sre-agent-incident-mapping-limitations.md#5-ui-autonomy-toggle-has-a-propagation-lag)).
  Config: `sre-agent-config/config.yaml → agent.mode: Autonomous`. (Step 0 prints a reminder but
  cannot toggle it for you.)
- ⚠️ **Lab deployed & healthy** the first time: `.\scripts\check-health.ps1` (spot-check sections
  5, 6, 20). Step 0 assumes the lab already exists — it starts/repairs, it does not deploy.
- ⚠️ **Knowledge & response plans applied**: `.\scripts\configure-sre-agent.ps1` (readiness report
  all green). This is what lets the agent use the on-prem triage skill and knowledge.
- ⚠️ **No stuck Fired alerts.** A clab alert left in `Fired`/`Acknowledged` will *mask* the new
  firing. Step 0's fabric repair + Step 1's incident clear usually resolve this, but if an alert is
  wedged, wait for the CM to go green and the alert to auto-**Resolve** before injecting.

### Screen layout for the recording
- **Left / terminal:** `scripts/demo.ps1` (drives the demo and live-tails the investigation).
- **Right / browser:** the portal SRE Agent → the incident thread (full transcript, the
  agent's approvals/actions, and the resource graph). The terminal tail and the portal thread
  show the same investigation from two angles.

---

## 2. Run it

```powershell
# Take B (on-prem fabric) — recommended first; most visual cascade
.\scripts\demo.ps1 -Scenario clab -Interactive

# Take A (Azure)
.\scripts\demo.ps1 -Scenario azure -Interactive
```

`-Interactive` pauses before each phase so you can narrate; drop it for an unattended
rehearsal. Useful switches: `-PreflightOnly` (run Step 0 and stop — warm/verify the lab),
`-SkipPreflight` (skip Step 0 on an already-warm lab), `-TimeoutMinutes 30` (how long to watch),
`-NoRevert` (leave the fault in for a follow-up shot), `-SkipClear`, `-NoWatch`,
`-FaultName <any inject-fault scenario>`.

### What each phase does (and what to say)

| Phase | Script action | Talk track |
|-------|---------------|------------|
| **0 · Pre-flight** | `az account show`; start deallocated source VMs; (clab) probe `172.31.20.10` and rebuild fabric+wiring via `onprem-clab-up.sh` if broken | *"First the script makes sure the lab is actually up — it starts any deallocated VMs and repairs the on-prem fabric — so the only thing that breaks the environment is the fault I inject next, not a cold VM."* |
| **1 · Clear** | `clear-incidents.ps1 -Force` | *"Now I delete old incidents. The agent dedups per alert-rule over a 7-day window, so a stale incident would absorb this new alert instead of opening a clean investigation."* |
| **2 · Inject** | `inject-fault.ps1 -Scenario <fault>` | *"Now I break exactly one thing. Notice every resource still reports healthy — this is the subtle kind of fault that takes an expert hours."* |
| **3 · Watch** | `watch-incidents.ps1` live-tail | *"Within a couple of minutes the Connection Monitor fails, the metric alert fires, and the agent opens an incident. Watch it build a plan, pull telemetry, run diagnostics, and reason toward the root cause."* |
| **4 · Revert** | `inject-fault.ps1 … -Revert` | *"Finally I restore the environment for the next take."* (Skip with `-NoRevert` if the agent already remediated it and you want to show the healthy state.) |

---

## 3. Timing expectations (so the video doesn't feel stuck)

| Milestone | Typical latency after inject |
|-----------|------------------------------|
| Connection Monitor test starts failing | ~1–3 min |
| Metric alert fires (sustained breach) | ~3–7 min |
| Agent scanner opens the incident (1-min poll) | ~+1 min after the alert |
| Agent reaches a root-cause verdict | ~5–20 min of investigation |

> **Total wall-clock is ~10–30 min per take.** For a tight video, **record the inject, then
> cut** to the moment the incident opens (the tail prints a green `Incident opened:` banner),
> and again to the root-cause message. The terminal tail flags each step (`⚙ used: az CLI`,
> `knowledge/memory`, `files/skills`, `plan/todos`) so the cut points are obvious.

---

## 4. Reset & rollback

- The demo **auto-reverts** the fault in phase 4. To leave it injected, pass `-NoRevert`; then
  revert manually: `.\scripts\inject-fault.ps1 -Scenario <fault> -Revert`.
- Clear the demo incident afterwards: `.\scripts\clear-incidents.ps1 -Force`.
- Re-verify health: `.\scripts\check-health.ps1` (and, for clab, the OSPF/BGP recovery).

---

## 5. Troubleshooting the demo

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No incident appears after ~10 min | Alert never fired, or a stale incident absorbed it | Confirm the CM is failing and the alert fired; re-run phase 1 clear; check `agentMode` |
| Incident opens but agent only *proposes*, never acts | Agent still in **Review** (stale UI toggle) | Refresh the portal; confirm Autonomous; delete the incident and let a fresh one open (mode is frozen at creation) |
| A second, parallel incident opens for the same fault | Per-rule dedup — one fault trips two alert rules; no cross-signal merge | Expected; see the [mapping-limitations doc](./sre-agent-incident-mapping-limitations.md). Follow either incident |
| Re-running the same take does nothing | Response-plan `cooldownHours` gate | Lower cooldown or clear the prior incident |
| Investigation ends with *"internal error"* | Platform-side transient | Delete the incident and re-inject; not a knowledge fault |
| Tail can't get a token / 401 | `az login` / audience | The watcher refreshes automatically; if it persists, re-`az login` |

---

## 6. Related docs

- [*Why networking SRE is a different (and harder) problem*](../README.md#why-networking-sre-is-a-different-and-harder-problem)
- [SRE Agent configuration — how it works](./sre-agent-configuration.md) (detection model, object model)
- [Alert→incident mapping limitations](./sre-agent-incident-mapping-limitations.md) (over/under-merge, autonomy, cooldown)
- [On-prem network topology](../knowledge/onprem-network-topology.md) (the OSPF→BGP→CM cascade for Take B)

---

*Companion docs:*
[SRE Agent configuration — how it works](./sre-agent-configuration.md)
· [SRE Agent — alert→incident mapping limitations](./sre-agent-incident-mapping-limitations.md)
· [Docs index](./README.md)
