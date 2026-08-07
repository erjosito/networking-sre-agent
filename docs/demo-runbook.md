# SRE Agent — Live Demo Runbook (for video recording)

> **📍 Part A — Azure Networking SRE.** A repeatable, on-camera demo of the Azure SRE
> Agent detecting → investigating → root-causing → fixing a networking fault.
> Driver script: [`scripts/demo.ps1`](../scripts/demo.ps1). See the [docs hub](./README.md).

Two takes are provided, both driven by the same one command:

| Take | Command | Fault | The story |
|------|---------|-------|-----------|
| **A — Azure** | `.\scripts\demo.ps1 -Scenario azure -Interactive` | `udr-wrong-nexthop` | A spoke's default route next-hop is repointed to an unreachable IP — the classic *"next-hop off by one"* black-hole. Every resource still looks healthy; only the Connection Monitors fail. |
| **B — On-prem fabric** | `.\scripts\demo.ps1 -Scenario clab -Interactive` | `clab-ospf-area-mismatch` | An OSPF area mismatch on the containerlab fabric drops the adjacency, withdraws the peer loopback, tears down BGP-over-loopback, and withdraws the LAN — a **control-plane cascade** the agent must unwind OSPF-first. |

Each take runs the same phases: **pre-flight → inject → watch → revert** (pre-flight always
runs and folds the incident-clear and a clean-baseline check into itself).

---

## 0. Why these two faults

They are the flagship examples from the [*why networking SRE is different*](../README.md#why-networking-sre-is-a-different-and-harder-problem)
narrative: the **symptom is identical** ("can't reach X", Connection Monitor fails) but the
**root cause hides in a different layer** each time (an Azure UDR vs. an on-prem OSPF
adjacency). They show the agent doing the expensive part — multi-layer correlation — in
minutes instead of hours.

---

## 1. Pre-flight checklist (before you hit record)

> **The demo script does this automatically — Step 0 pre-flight ALWAYS runs and auto-fixes.**
> There is no way to skip it (and no reason to): a clean baseline is what makes the demo
> repeatable. `demo.ps1` verifies `az login`, **starts every deallocated lab VM**, (clab)
> **rebuilds the fabric + host-probe wiring** if broken, **deletes any existing SRE Agent
> incidents**, and then **waits until the scenario's Connection Monitors report GREEN** before it
> will inject. Run `.\scripts\demo.ps1 -Scenario clab -PreflightOnly` to warm and verify the lab
> ahead of time. The items below are what the script does *for* you (✅) versus what still needs
> your eyes (⚠️).

- ✅ **All VMs started.** Step 0 enumerates every VM in the resource group and starts the ones that
  are deallocated, then waits until they report *running*. This matters because a down VM — whether
  a CM **source or destination** — fails its Connection Monitor and fires alerts (and opens
  incidents) that have nothing to do with the demo. Starting only the scenario's source VM is not
  enough; the whole lab must be up for a clean green baseline.
- ✅ **App Gateways started.** Step 0 enumerates the Application Gateways and starts any that are
  `Stopped`. Both hub App Gateways front the `netsre-webapp` Traffic Manager profile — when they are
  stopped the TM endpoints go **Degraded** and the `onprem-to-webapp` Connection Monitor fails
  (`rtt=None`), so the baseline is never fully green until they are `Running` again. (App Gateways
  are stopped to save cost between demos; starting one takes a few minutes.)
- ✅ **clab fabric + host-probe wiring.** The `clabr1host` veth IP and the host route
  `172.31.20.0/24 via 172.31.11.2` are **not** durable across a VM reboot *or* a `containerlab
  deploy --reconfigure` (which recreates the veth without its IP). When they are missing, a **stale
  route sends the probe over the docker management bridge** (`172.31.20.0/24 via 172.20.20.x`)
  straight to the in-fabric host container — so `ping 172.31.20.10` still succeeds but **bypasses the
  r1→r2 fabric**, and no OSPF/BGP fault can ever turn the Connection Monitor red. Step 0 therefore
  **re-applies the wiring idempotently and verifies the probe egresses `clabr1host`** (the fabric),
  not the mgmt bridge — a passing ping alone is not trusted. If you ever need to do it by hand:
  ```bash
  ip addr replace 172.31.11.1/30 dev clabr1host
  ip link set dev clabr1host up
  ip route replace 172.31.20.0/24 via 172.31.11.2 dev clabr1host
  # verify the path (NOT just reachability): ip route get 172.31.20.10  → must show 'dev clabr1host'
  ```
- ✅ **No stuck/stale incidents.** Step 0 runs `clear-incidents.ps1 -Force`, deleting prior
  incidents (including ones left `Acknowledged`/`Resolved` from earlier runs) so the new alert opens
  a *fresh* investigation. Pre-check with `.\scripts\clear-incidents.ps1 -ListOnly`.
- ✅ **Baseline Connection Monitors green.** After starting VMs and App Gateways, Step 0 polls Log
  Analytics until **every** Connection Monitor in the environment reports `Pass` (not just the
  scenario's source — up to `-BaselineTimeoutMinutes`, default 15) — so you inject into a
  *known-healthy* environment and the only red is the one you cause.
- ✅ **Agent in Autonomous mode** so it *acts* on-camera, not just proposes. **Step 0 reads the
  agent's `properties.actionConfiguration.mode` and, if it is not `Autonomous`, offers to switch it
  for you** (auto-switches when non-interactive; asks first with `-Interactive`). Note the toggle has
  a propagation lag — if a just-opened incident still only proposes, refresh the portal and let a
  fresh incident open (see the
  [mapping-limitations doc](./sre-agent-incident-mapping-limitations.md#5-ui-autonomy-toggle-has-a-propagation-lag)).
  Config default: `sre-agent-config/config.yaml → agent.mode: Autonomous`.
- ⚠️ **Lab deployed & healthy** the first time: `.\scripts\check-health.ps1` (spot-check sections
  5, 6, 20). Step 0 assumes the lab already exists — it starts/repairs, it does not deploy.
- ⚠️ **Knowledge & response plans applied**: `.\scripts\configure-sre-agent.ps1` (readiness report
  all green). This is what lets the agent use the on-prem triage skill and knowledge.

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
rehearsal. Useful switches: `-Timeline` (timestamp every action **and** watch for each cascade
event — see §3), `-PreflightOnly` (run pre-flight and stop — warm/verify the lab),
`-TimeoutMinutes 30` (how long to watch), `-BaselineTimeoutMinutes 15` (how long pre-flight waits
for CMs to go green), `-NoRevert` (leave the fault in for a follow-up shot), `-NoWatch`,
`-FaultName <any inject-fault scenario>`. Pre-flight always runs — there is no skip switch.

### What each phase does (and what to say)

| Phase | Script action | Talk track |
|-------|---------------|------------|
| **0 · Pre-flight** *(always)* | `az account show`; start **all** deallocated VMs; start any stopped **App Gateways** (they front the webapp Traffic Manager); (clab) rebuild fabric+wiring via `onprem-clab-up.sh` if `172.31.20.10` is unreachable; `clear-incidents.ps1 -Force`; wait until **all** Connection Monitors report `Pass`; verify the agent is in **Autonomous** mode (offer to switch if not) | *"First the script makes the lab clean: it starts every VM, repairs the on-prem fabric, deletes old incidents, and waits for all Connection Monitors to go green — so the only thing red after this is the fault I inject next. Old incidents matter because the agent dedups per alert-rule over a 7-day window, and a stale one would swallow my new alert."* |
| **1 · Inject** | `inject-fault.ps1 -Scenario <fault>` | *"Now I break exactly one thing. Notice every resource still reports healthy — this is the subtle kind of fault that takes an expert hours."* |
| **2 · Watch** | `watch-incidents.ps1 -Quiet` — follows the investigation silently and prints only the **final message(s)** when the agent finishes, the incident resolves, or activity **stalls** for 3 min (with `-Timeline`, a cascade watcher runs first) | *"Rather than scroll every message, I let it work and show the conclusion. Within a couple of minutes the Connection Monitor fails, the metric alert fires, and the agent opens an incident — then it builds a plan, pulls telemetry, runs diagnostics, and reasons to the root cause."* |
| **3 · Revert** | First checks whether the **agent already remediated** the fault (scenario Connection Monitor GREEN again). If so it says so and skips the manual revert (non-interactive) or asks whether to revert anyway (`-Interactive`); otherwise `inject-fault.ps1 … -Revert` | *"The script verifies whether the agent fixed it on its own before I touch anything — if connectivity is already restored there's nothing to revert; otherwise it restores the environment for the next take."* (`-NoRevert` leaves it as-is.) |

---

## 3. Timing expectations & `-Timeline` mode

Run a rehearsal with **`-Timeline`** to timestamp every action and actively watch for each event
in the cascade — the script records the *true* time of each and prints a summary table at the end:

```powershell
.\scripts\demo.ps1 -Scenario clab -Timeline      # unattended rehearsal with timings
```

It watches (and stamps `⏱ …Z (T+mm:ss)` as each occurs): baseline CMs green, **fault injected
(T0)**, Connection Monitor goes **red** (Log Analytics `NWConnectionMonitorTestResult`), **syslog**
BGP/OSPF message arrives (clab only, best-effort — the FRR→host forwarder may not always deliver),
the **metric alert fires** (`Microsoft.AlertsManagement/alerts`), the **SRE Agent opens the
incident** (threads API), and — after remediation — the **CM recovers green**. While waiting for
these it prints a `T+mm:ss` heartbeat listing which prerequisite events are still pending (e.g.
`waiting for: alert, incident`) so you can see the alert-before-incident gap in real time. Then it
follows the agent's investigation **quietly** (`watch-incidents.ps1 -Quiet`) and prints only the
final message(s) once the agent finishes, the incident resolves, or activity stalls — keeping the
screen calm on camera instead of scrolling every message.

Typical latencies after inject (use these to plan cuts):

| Milestone | Typical latency after inject |
|-----------|------------------------------|
| Connection Monitor test starts failing | ~1–3 min |
| Metric alert fires (sustained breach; `PT5M`/`PT5M`) | ~3–7 min |
| Agent scanner opens the incident (1-min poll) | ~+1 min after the alert |
| Agent reaches a root-cause verdict | ~5–20 min of investigation |

> **Total wall-clock is ~10–30 min per take.** For a tight video, **record the inject, then
> cut** to the moment the incident opens (the tail prints a green `Incident opened:` banner),
> and again to the root-cause message. The terminal tail flags each step (`⚙ used: az CLI`,
> `knowledge/memory`, `files/skills`, `plan/todos`) so the cut points are obvious.

---

## 4. Reset & rollback

- The demo **auto-reverts** the fault in the revert phase. To leave it injected, pass `-NoRevert`;
  then revert manually: `.\scripts\inject-fault.ps1 -Scenario <fault> -Revert`.
- Clear the demo incident afterwards: `.\scripts\clear-incidents.ps1 -Force` (or just let the next
  run's pre-flight do it).
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
| Agent stalls asking to **grant permissions** (OBO fallback) | Identity lacks a role for the action — commonly `connectionMonitors/query/action` in **NetworkWatcherRG**, or `runCommand/action` on a VM | Ensure the identity has **Network Contributor on the subscription** and **Virtual Machine Contributor on the RG** (both now in bicep: `sre-agent-sub-roles.bicep`, `sre-agent.bicep`). Re-deploy those modules if remediating an older environment |
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
