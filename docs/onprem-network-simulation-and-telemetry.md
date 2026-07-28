# Extending the SRE Agent Story to On-Premises Networking

> **Status:** Design exploration / RFC
> **Audience:** Maintainers of `networking-sre-agent`
> **Goal:** Evaluate how to (a) *simulate* on-premises network devices and (b) make their
> *telemetry* (syslog **and** metrics) available to the Azure SRE Agent, in a way that fits the
> existing multi-hub hub-and-spoke testbed.

---

## 1. Context — where we are today

The current "on-premises" side of the lab (`infra/modules/onprem.bicep`) is **not** a network
device at all. It is:

- an Azure VNet (`10.100.0.0/16`) with a **route-based VPN Gateway** (BGP ASN 65100),
- a single **plain Ubuntu 22.04 test VM** (a *workload*, not a router),
- an NSG + NAT Gateway for outbound, and
- the **Network Watcher Agent** extension for Connection Monitor probes.

So "on-prem" today is really *another Azure VNet that pretends to be on-prem via S2S VPN + BGP*.
Telemetry reaching the SRE Agent is **exclusively Azure-native**: Connection Monitor results,
Azure Monitor metrics (VPN Gateway, LB), and Activity Log. There is **no device-level telemetry**
(no syslog, no SNMP, no streaming telemetry) and **no simulated router/firewall/switch** whose
config or control plane can fail in an interesting way.

The extension therefore has two independent problems:

1. **Simulation** — introduce something that *behaves like* an on-prem network device (routing,
   config, control-plane state that can break).
2. **Telemetry** — get that device's operational signals into a place the SRE Agent can reason
   over (Azure Monitor / Log Analytics), the same way Connection Monitor alerts drive it today.

> **Terminology note:** the metrics protocol for legacy network gear is **SNMP** (Simple Network
> Management Protocol). The rest of this document uses SNMP.

---

## 2. Part A — Simulating on-premises network devices

The realism you get is a spectrum. Higher fidelity = higher cost, licensing friction, and
operational weight. Five broad options, roughly in increasing fidelity:

### A1. "Soft router" on a normal Linux VM (FRRouting / BIRD / VyOS) — *lowest friction*
Turn the existing on-prem Ubuntu VM (or a new one) into a router using open-source routing stacks:

- **FRRouting (FRR)** — production-grade BGP/OSPF/IS-IS, Cisco-like `vtysh` CLI, emits **syslog**
  and exposes counters. Already conceptually aligned: the hub NVAs are Ubuntu boxes, so this reuses
  existing patterns and cloud-init.
- **VyOS** — full network-OS *distribution* (Juniper-like CLI, config commit/rollback, built-in
  BGP/OSPF/firewall/VPN). Feels much more like "a device" than raw Linux and has an Azure image.
- **BIRD** — lightweight, BGP/OSPF only.

**Pros:** free, Azure-native VM (no nested virt), scriptable faults via cloud-init/`az vm run-command`,
native syslog, good BGP fidelity for the VPN/BGP story you already tell.
**Cons:** not a "real" vendor NOS — no vendor-specific syslog message IDs, no vendor MIBs, data-plane
features are Linux-flavored. Good enough for *control-plane* incident stories.

### A2. Containerized network OS via **Containerlab** — *high fidelity, modern*
[Containerlab](https://containerlab.dev/) orchestrates container-based NOSes on a single Linux host:

- Free/openly available images: **Nokia SR Linux**, **Arista cEOS** (free with account), **FRR**,
  **SONiC**, **Cisco XRd**.
- Topologies are declarative YAML; you can stand up a small "on-prem campus/WAN" (a couple of
  routers + a switch) inside one Azure VM.

**Pros:** realistic vendor CLIs, real syslog formats, real SNMP MIBs / gNMI streaming telemetry,
fast to spin up/tear down, fault injection = `containerlab` + config pushes.
**Cons:** needs a beefy Linux host VM; some images need a (free) vendor account; SR Linux/Arista
data-plane is containerized (control-plane-accurate, data-plane simplified). Best telemetry realism
for the least licensing pain.

### A3. VM-based virtual appliances (vendor NOS images) — *highest fidelity, licensing cost*
Run real vendor images as Azure VMs or nested under a hypervisor:

- **Cisco Catalyst 8000V / CSR1000v**, **Arista vEOS**, **Juniper vMX / vSRX**,
  **Palo Alto VM-Series**, **Fortinet FortiGate-VM** — several are in the **Azure Marketplace**.
- Marketplace NVAs can attach straight to the on-prem VNet and terminate the S2S VPN / speak BGP.

**Pros:** production-identical CLI, syslog, SNMP MIBs, streaming telemetry, WAF/IPS features.
**Cons:** **licensing** (BYOL or hourly Marketplace fees), larger VM SKUs, slower deploy, and cost.
Overkill unless you specifically want vendor-accurate incidents.

### A4. Nested emulation — **EVE-NG / GNS3 / Cisco Modeling Labs** on one Azure VM
Run a network emulator inside a single VM that supports **nested virtualization**
(Azure `Dv3/Ev3/Dv5` families support it). Import IOSv/vIOS/other qcow2 images and build arbitrarily
complex multi-device topologies.

**Pros:** richest topologies, closest to a real "on-prem network" with many device types.
**Cons:** heaviest to automate (not IaC-friendly), image licensing, nested-virt SKU constraints,
fragile for CI/repeatable fault injection. Great for demos, poor for a repeatable testbed.

### A5. Pure simulation / mock telemetry — *no real device at all*
Skip the device entirely and **generate synthetic telemetry** (fake syslog lines + fake SNMP/metric
series) that describe an imaginary device, then break the *data* on demand.

**Pros:** trivial, cheap, fully deterministic fault injection, zero licensing.
**Cons:** no real control/data plane — the agent can't actually *verify* anything, so root-cause
stories are shallow. Useful as a **stopgap** to build the telemetry pipeline before a real device
exists.

### Simulation comparison

| Option | Fidelity | Cost/Licensing | IaC-friendly | Nested virt? | Real syslog | Real SNMP/telemetry |
|--------|----------|----------------|--------------|--------------|-------------|---------------------|
| A1 FRR/VyOS on VM | Medium (control plane) | Free | ✅ High | No | ✅ (Linux) | Partial (net-snmp) |
| A2 Containerlab | High | Free/free-tier | ✅ Medium | No (containers) | ✅ Vendor | ✅ Vendor MIBs/gNMI |
| A3 Vendor VM/Marketplace | Very high | 💲 BYOL/hourly | ✅ Medium | No | ✅ Vendor | ✅ Vendor |
| A4 EVE-NG/GNS3 nested | Very high | 💲 Images | ❌ Low | Yes | ✅ Vendor | ✅ Vendor |
| A5 Synthetic telemetry | Low | Free | ✅ High | No | Faked | Faked |

**Recommendation:** start with **A1 (FRR or VyOS)** to reuse the existing VM/cloud-init/BGP patterns,
and offer **A2 (Containerlab)** as an optional high-fidelity add-on. This keeps the lab deployable,
cheap, and repeatable while still producing *real* syslog and SNMP.

---

## 3. Part B — Getting telemetry to the SRE Agent

The SRE Agent reasons over **Azure Monitor** (Log Analytics logs + metrics + alerts). So every
approach below funnels device signals into a **Log Analytics workspace** and/or an **Azure Monitor
(Prometheus) workspace**, then exposes them via alerts — exactly like the Connection Monitor path
that already drives the agent.

### 3.1 Syslog (the part you already have a handle on)

Your instinct is correct. The standard pattern:

```
Network device(s) ──UDP/TCP 514 (syslog / CEF)──▶ Linux "collector" VM
        (rsyslog / syslog-ng)  ──▶  Azure Monitor Agent (AMA)  ──▶  DCR  ──▶  Log Analytics
                                                                     └─ Syslog / CommonSecurityLog table
```

Key points:
- **AMA replaces the legacy Log Analytics agent (MMA/OMS), which is retired.** Use **AMA** + a
  **Data Collection Rule (DCR)** with the **Syslog** data source (facilities/severities) — or the
  **CEF** data source (→ `CommonSecurityLog`) for firewall/security devices.
- The device itself does **not** run AMA. It just points its syslog exporter at the collector VM.
  AMA runs on the collector.
- For a *non-Azure* device you'd use **Azure Arc** to project it as a server and install AMA; but
  because our "on-prem" lives in Azure, we can just run AMA on an Azure collector VM directly.
- Parsing: vendor syslog is free-form. Normalize with rsyslog templates or a
  **transformKql** in the DCR to extract severity, facility, message-ID, interface, etc.

This gives the agent a `Syslog` / `CommonSecurityLog` table it can KQL over and alert on (e.g.
`%BGP-5-ADJCHANGE`, interface flaps, IPsec SA down).

### 3.2 Metrics — the hard part (SNMP and friends)

AMA does **not** collect SNMP. Legacy gear predates push-based telemetry, so you need a **poller**
that turns SNMP (or newer streaming telemetry) into something Azure Monitor stores. Four viable
approaches:

#### B1. **Telegraf** with the SNMP input plugin → Azure Monitor *(recommended for legacy gear)*
- Run [Telegraf](https://github.com/influxdata/telegraf) on the collector VM.
- `inputs.snmp` polls device OIDs/MIBs on a schedule.
- Output options:
  - `outputs.azure_monitor` → Azure Monitor **custom metrics** (per-resource, alertable), **or**
  - `outputs.http` → **Logs Ingestion API** (DCR + custom `_CL` table in Log Analytics), **or**
  - Prometheus remote-write → Azure Monitor workspace.
- **Pros:** huge library of vendor SNMP MIBs, mature, single agent can also do NetFlow/gNMI/ping.
- **Cons:** you manage the Telegraf config/MIBs; custom-metrics dimensionality limits apply.

#### B2. **Prometheus `snmp_exporter` + Azure Monitor managed Prometheus**
- `snmp_exporter` scrapes SNMP and exposes Prometheus metrics; an agent (AMA Prometheus / OTel)
  remote-writes to an **Azure Monitor workspace**; visualize in **Azure Managed Grafana**.
- **Pros:** cloud-native metrics model, PromQL, great dashboards, alert rules → the agent.
- **Cons:** more moving parts (`snmp_exporter` + `generator.yml` per MIB); metrics only.

#### B3. **OpenTelemetry Collector** (SNMP receiver / gNMI) → Azure Monitor exporter
- The OTel Collector `snmpreceiver` (or a gNMI receiver for modern NOSes) → `azuremonitorexporter`
  or Prometheus remote-write.
- **Pros:** one pipeline for logs+metrics+traces, future-proof, vendor-neutral.
- **Cons:** SNMP receiver is less mature than Telegraf's; more assembly.

#### B4. **Streaming telemetry (gNMI / model-driven)** — for *modern* NOSes only
- SR Linux / Arista / Cisco XR push **gNMI/gRPC** telemetry (subscriptions) — no polling, low
  latency, structured. Consume via Telegraf `inputs.gnmi` or OTel and forward as above.
- **Pros:** the "right" modern answer; rich, high-frequency, structured.
- **Cons:** only available on modern devices (so pairs with simulation A2/A3, not legacy emulation).

#### Bonus: flow telemetry (NetFlow / IPFIX / sFlow)
For *traffic* (not device-health) telemetry, add a **NetFlow/IPFIX/sFlow** collector (Telegraf,
`nfdump`, or a vendor collector) → Log Analytics. This is the on-prem analog of NSG flow logs /
Traffic Analytics and enables "who's talking to whom" incident stories.

### Telemetry comparison

| Signal | Protocol | Collector | Lands in | Best for |
|--------|----------|-----------|----------|----------|
| Logs/events | Syslog / CEF | rsyslog + **AMA** + DCR | `Syslog` / `CommonSecurityLog` | Config changes, BGP/IPsec events |
| Health metrics | **SNMP** | **Telegraf** / snmp_exporter / OTel | Azure Monitor metrics or `_CL` table | CPU, mem, interface counters, errors |
| Modern metrics | **gNMI** | Telegraf/OTel | Azure Monitor / Prometheus | High-fidelity streaming (A2/A3 only) |
| Traffic flows | NetFlow/IPFIX/sFlow | Telegraf/nfdump | `_CL` table | Flow/volume anomalies |

**Recommended pipeline:** a single **"on-prem collector" Azure VM** running **rsyslog + AMA**
(syslog) **and Telegraf** (SNMP → Logs Ingestion API / custom metrics). One VM, two well-trodden
tools, everything lands in the same Log Analytics workspace the agent already uses.

---

## 4. Part C — Making it *consumable* by the SRE Agent

Getting data into Log Analytics is necessary but not sufficient — the agent needs **triggers** and
**knowledge**:

1. **Alert rules** — mirror the existing `<prefix>-cm-checks-failed` pattern. Create
   scheduled-query (KQL) alerts over `Syslog` / SNMP tables (e.g. "BGP neighbor down",
   "interface error rate rising", "IPsec SA torn down", "device CPU > 90%"). These fire the agent,
   just like Connection Monitor does today. Keep the `titleContains`/prefix isolation convention so
   multiple deployments don't cross-trigger.
2. **Knowledge base** — add a `knowledge/onprem-device-telemetry.md` (and maybe
   `onprem-routing-frr-vyos.md`) so the agent understands device syslog message IDs, key SNMP OIDs,
   and how on-prem BGP/IPsec relates to the Azure VPN Gateway side.
3. **Custom skill** — add a `sre-agent-config/skills/onprem-device-diagnostics/` skill with the
   KQL queries and a decision tree (syslog event → SNMP counter → correlate with Azure VPN Gateway
   `TunnelDiagnosticLog` / `RouteDiagnosticLog`).
4. **Correlation story** — the *value* is cross-domain: e.g. an on-prem BGP flap (device syslog)
   explains an Azure-side Connection Monitor failure. Give the agent both sides so it can join them.

---

## 5. Part D — Fault injection for on-prem devices

To keep parity with `scripts/inject-fault.ps1` (26 scenarios, each with a clean `-Revert`), add
on-prem device scenarios such as:

- `onprem-bgp-shutdown` — `neighbor <ip> shutdown` in FRR/VyOS → BGP flap + syslog + Azure VPN BGP down.
- `onprem-mtu-mismatch` — interface MTU change → fragmentation/timeouts (subtle, realistic).
- `onprem-acl-block` — device ACL dropping a prefix → asymmetric reachability.
- `onprem-ipsec-rekey-fail` — bad IKE/IPsec params → VPN flapping (pairs with existing VPN faults).
- `onprem-cpu-spike` — stress the device → SNMP CPU high + slow control plane.
- `onprem-interface-flap` — bounce an interface → syslog link events + SNMP counter jumps.

Each should be injectable via `az vm run-command` / config push and cleanly revertible, matching the
repo's existing design principle of "subtle, realistic, observable, reversible."

---

## 6. Challenges you may not have flagged yet

1. **AMA ≠ SNMP.** AMA collects syslog/perf-counter/text logs but has **no SNMP capability** — the
   SNMP-to-Azure gap is the real work, and needs a separate poller (Telegraf/exporter). *(This is
   the crux of your metrics concern.)*
2. **Legacy agent retirement.** Don't build on the old Log Analytics agent (MMA/OMS) — it's retired;
   use **AMA + DCR** only.
3. **Nested virtualization constraints.** A4 (EVE-NG/GNS3) requires nested-virt-capable Azure SKUs
   (`Dv3/Ev3/Dv5`…), which affects cost and region availability.
4. **Vendor image licensing & cost.** A3/A4 realism comes with BYOL/Marketplace fees and larger
   SKUs — a real budget line item, and a friction point for a "clone-and-deploy" lab.
5. **Data-plane vs control-plane fidelity.** Containers (A2) and soft routers (A1) are
   control-plane-accurate but data-plane-simplified. Be explicit about which incidents are in scope.
6. **Syslog normalization.** Vendor syslog is unstructured and inconsistent across vendors —
   you'll need parsing (rsyslog templates / DCR `transformKql` / grok) to make it queryable, and
   the parsing is per-vendor.
7. **Log Analytics ingestion cost & cardinality.** SNMP-per-interface and high-frequency streaming
   telemetry can explode ingestion GB and metric time-series cardinality. Sample/aggregate at the
   collector, and watch custom-metric dimension limits.
8. **Time sync / NTP.** Cross-domain correlation (device syslog ↔ Azure logs) only works if clocks
   agree. Ensure NTP on the collector and devices; account for `TimeGenerated` vs device timestamp.
9. **Credential & secret management.** SNMPv2c community strings are plaintext — prefer **SNMPv3**
   (auth/priv). Store community strings / gNMI certs / device creds in **Key Vault**, not cloud-init.
10. **Reachability of the collector.** The collector must reach devices (SNMP/syslog) *and* Azure
    Monitor ingestion endpoints — mind NSGs, UDRs (all traffic in this lab traverses the NVA!),
    private-link/DCE for Log Analytics, and the on-prem VNet's NAT Gateway egress.
11. **A single collector is a SPOF** for the whole telemetry story — fine for a lab, worth calling
    out; syslog over UDP silently drops if the collector is down.
12. **Repeatability / IaC.** Anything not expressible in Bicep + cloud-init (esp. A4) undermines the
    repo's "deploy in one script" promise and complicates CI and fault-injection revert paths.
13. **Two clocks of realism.** "On-prem in an Azure VNet over VPN" already isn't real on-prem
    (latency, NAT, MTU, provider edge). Adding a device improves device realism but not WAN realism —
    set expectations accordingly.

---

## 7. Suggested phased approach

1. **Phase 0 — pipeline first (A5 + syslog):** stand up the collector VM (rsyslog + AMA + DCR) and,
   optionally, synthetic telemetry. Prove syslog → Log Analytics → alert → SRE Agent end-to-end.
2. **Phase 1 — real control plane (A1):** convert/​add an FRR or VyOS on-prem router speaking BGP to
   both hubs; emit real syslog; add Telegraf SNMP for CPU/interface metrics.
3. **Phase 2 — fault parity:** add `onprem-*` scenarios to `inject-fault.ps1`, knowledge doc, and a
   custom skill; wire KQL alerts on device signals.
4. **Phase 3 — high fidelity (optional, A2):** offer a Containerlab-based multi-device on-prem
   topology with gNMI streaming telemetry for advanced demos.

This delivers a working, cheap, repeatable story early (Phases 0–1) and reserves vendor-grade
realism (A2/A3) as an opt-in.
