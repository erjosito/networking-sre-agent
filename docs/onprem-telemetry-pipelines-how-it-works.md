# On-Prem Telemetry Pipelines — How It Works

This document explains, end to end, how telemetry from the simulated on-prem
network devices reaches Azure Monitor. It covers the **three concrete pipelines**
that are implemented in this repository:

| # | Pipeline | Source | Transport | Azure destination |
|---|----------|--------|-----------|-------------------|
| 1 | **Syslog** | any device (`rsyslog`) | UDP/514 → collector → AMA | **Logs** — `Syslog` table |
| 2 | **SNMP metrics** | FRR router (`snmpd`) | Telegraf SNMP poll → managed identity | **Metrics** — custom namespaces on the VM |
| 3 | **RADIUS AAA audit** | FRR router (`pam_radius`) | RADIUS → FreeRADIUS log → AMA text log | **Logs** — `OnPremAAA_CL` table |

The **collector VM** (`<prefix>-onprem-collector`, static IP `10.100.1.100`) is the
hub for all three: it runs `rsyslog`, `snmpd`, **Telegraf**, **FreeRADIUS**, and the
**Azure Monitor Agent (AMA)**. The **FRR router** (`<prefix>-onprem-frr`, `10.100.1.201`)
is the simulated "network device" that emits syslog, answers SNMP, and delegates
operator logins to RADIUS.

> This is the *implementation* companion to the design/decision doc
> [`onprem-network-simulation-and-telemetry.md`](./onprem-network-simulation-and-telemetry.md).
> If you want the "why we chose this" rationale and the alternatives we rejected,
> read that one; this doc is the "how the wires actually run".

---

## 0. The big picture

```mermaid
flowchart LR
    subgraph DEV["Network device · netsre-onprem-frr (10.100.1.201)"]
        RSD["rsyslog<br/>*.* @collector:514"]
        SNMPD["snmpd<br/>udp:161"]
        PAM["sshd + pam_radius_auth"]
    end

    subgraph COL["Collector · netsre-onprem-collector (10.100.1.100)"]
        RSC["rsyslog<br/>imudp/imtcp :514"]
        TG["Telegraf<br/>SNMP input"]
        FR["FreeRADIUS<br/>:1812"]
        LOG["/var/log/freeradius/radius.log"]
        AMA["Azure Monitor Agent"]
    end

    subgraph AZ["Azure Monitor"]
        LAW[("Log Analytics<br/>netsre-law")]
        MET[("Metrics<br/>custom namespaces")]
    end

    RSD -->|"UDP 514"| RSC
    RSC --> AMA
    SNMPD -->|"SNMP GET/poll"| TG
    PAM -->|"RADIUS Access-Request<br/>UDP 1812"| FR
    FR --> LOG --> AMA

    AMA -->|"Syslog DCR"| LAW
    AMA -->|"text-log DCR + DCE"| LAW
    TG -->|"managed identity<br/>Metrics Publisher"| MET

    classDef azure fill:#e6f0ff,stroke:#3366cc;
    class LAW,MET azure;
```

**Two destinations, and the distinction matters:**

- **Logs** (Syslog, AAA) land in the **Log Analytics workspace** and are queried
  with **KQL**. They flow through the **AMA + DCR** machinery.
- **Metrics** (SNMP) land in **Azure Monitor Metrics** as **custom metrics
  attached to the collector VM's resource ID**. They are charted/alerted in the
  Metrics explorer and never touch Log Analytics. They flow through **Telegraf +
  managed identity**, with **no DCR and no DCE**.

Keep that split in mind — it is the single most common source of confusion
("why isn't my SNMP data in KQL?").

---

## 1. Pipeline 1 — Syslog → Log Analytics

### What it does
Every device forwards **all** syslog facilities to the collector, where AMA reads
the local syslog stream and ships it to the `Syslog` table in `netsre-law`.

### Flow

```mermaid
sequenceDiagram
    participant D as Device (FRR/server/clab)
    participant RC as Collector rsyslog (:514)
    participant AR as AMA-managed rsyslog rule
    participant AMA as Azure Monitor Agent
    participant LAW as Log Analytics (Syslog)

    D->>RC: UDP/514  "*.* @collector:514"
    RC->>RC: write local copy<br/>/var/log/remote/HOST.log
    RC->>AR: forward via /run socket
    AR->>AMA: Microsoft-Syslog stream
    AMA->>LAW: DCR routes stream → workspace
    Note over AMA,LAW: Syslog DCR — no DCE needed
```

### Device side (`infra/cloud-init/frr-router.yaml`)
The router forwards everything to the collector. The collector IP is injected by
`onprem-router.bicep` via the `COLLECTOR_IP_PLACEHOLDER` token:

```
# /etc/rsyslog.d/90-forward.conf
*.* @COLLECTOR_IP_PLACEHOLDER:514
```

(`@` = UDP; `@@` would be TCP. The on-prem server uses the identical pattern.)

### Collector side (`infra/cloud-init/collector.yaml`)
`rsyslog` listens on 514 (UDP **and** TCP) and keeps a local per-host copy for
troubleshooting:

```
# /etc/rsyslog.d/10-remote.conf
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
template(name="RemoteHost" type="string" string="/var/log/remote/%HOSTNAME%.log")
if ($fromhost-ip != "127.0.0.1") then {
  action(type="omfile" dynaFile="RemoteHost")
}
```

### Azure side (`infra/modules/onprem-collector.bicep`)
Three resources make this work:

1. **AMA extension** on the collector VM (`AzureMonitorLinuxAgent`). When it
   installs, it drops its own rsyslog config that forwards the local syslog stream
   into a socket AMA listens on — this is how the received device logs reach AMA.
2. **Syslog DCR** (`<prefix>-onprem-syslog-dcr`) — collects the built-in
   `Microsoft-Syslog` stream, all facilities and levels, routed to the workspace:

   ```
   dataSources.syslog: [{ streams:[Microsoft-Syslog], facilityNames:[*], logLevels:[*] }]
   destinations.logAnalytics: [{ workspaceResourceId: <netsre-law> }]
   dataFlows: [{ streams:[Microsoft-Syslog], destinations:[law] }]
   ```

3. **DCR association** (`...-syslog-dcra`) scoped to the collector VM, which is
   what actually binds the DCR to that machine's AMA.

> **No DCE here.** The built-in `Microsoft-Syslog` stream uses the legacy Log
> Analytics ingestion path, which does not require a Data Collection Endpoint.
> (Contrast with the AAA pipeline below, which *does*.)

### Verify

```kql
Syslog
| where TimeGenerated > ago(1h)
| summarize count() by Computer, ProcessName
| order by count_ desc
```

---

## 2. Pipeline 2 — SNMP → Azure Monitor **Metrics**

### What it does
Telegraf on the collector **polls** the FRR router's SNMP agent every 60 s and
publishes the results as **custom metrics on the collector VM's resource ID**,
using the VM's **managed identity**. No DCR, no DCE, no Log Analytics.

### Flow

```mermaid
flowchart LR
    subgraph FRR["FRR router (10.100.1.201)"]
        SNMPD["snmpd<br/>agentaddress udp:161<br/>rocommunity public 10.0.0.0/8"]
    end
    subgraph COL["Collector (10.100.1.100)"]
        TG["Telegraf<br/>inputs.snmp (v2c, numeric OIDs)<br/>outputs.azure_monitor"]
        MI["VM managed identity"]
        IMDS["IMDS<br/>region + resourceId"]
    end
    MET[("Azure Monitor Metrics<br/>onprem/snmp · onprem/interface<br/>on the collector VM resource")]

    SNMPD -->|"SNMP GET udp:161<br/>MIB-2 + ifTable"| TG
    IMDS -.->|"auto-detect"| TG
    MI -.->|"Monitoring Metrics Publisher"| TG
    TG -->|"custom metrics API"| MET

    classDef azure fill:#e6f0ff,stroke:#3366cc;
    class MET azure;
```

### Device side (`infra/cloud-init/frr-router.yaml`)
`snmpd` must listen on **all** interfaces (not the package default of
localhost-only) so the collector can reach it:

```
# staged as /etc/snmp/snmpd.conf.onprem, installed in runcmd
agentaddress udp:161
rocommunity public 10.0.0.0/8
sysLocation onprem-frr
sysContact netops
sysServices 72
```

> ⚠️ **Overwrite, don't drop-in, for snmpd.** A drop-in `agentaddress udp:161`
> *concatenates* with the packaged default `agentaddress 127.0.0.1,[::1]` into a
> malformed endpoint and snmpd exits with "Error opening specified endpoint".
> We replace the whole file instead.

### Collector side (`infra/cloud-init/collector.yaml`)
Telegraf reads a **drop-in** under `/etc/telegraf/telegraf.d/` (loaded by the
packaged unit's `-config-directory`) so the package's own `telegraf.conf`
conffile stays pristine:

```toml
# /etc/telegraf/telegraf.d/onprem.conf
[[outputs.azure_monitor]]
  namespace_prefix = "onprem/"

[[inputs.snmp]]
  agents = ["udp://10.100.1.201:161"]
  version = 2
  community = "public"
  [[inputs.snmp.field]]
    name = "sysName"
    oid  = "1.3.6.1.2.1.1.5.0"
    is_tag = true
  [[inputs.snmp.field]]
    name = "sysUpTime"
    oid  = "1.3.6.1.2.1.1.3.0"
  [[inputs.snmp.table]]
    name = "interface"
    oid  = "1.3.6.1.2.1.2.2"
    [[inputs.snmp.table.field]]
      name = "ifDescr"
      oid  = "1.3.6.1.2.1.2.2.1.2"
      is_tag = true
    [[inputs.snmp.table.field]]
      name = "ifInOctets"
      oid  = "1.3.6.1.2.1.2.2.1.10"
    [[inputs.snmp.table.field]]
      name = "ifOutOctets"
      oid  = "1.3.6.1.2.1.2.2.1.16"
```

Notes:
- **Numeric OIDs** are used deliberately to avoid a MIB-file dependency on the box.
- `is_tag = true` fields become **metric dimensions** (`sysName`, `ifDescr`), which
  is how you tell devices/interfaces apart in the Metrics explorer.
- The `[[inputs.snmp.table]]` walks the standard `ifTable` (`1.3.6.1.2.1.2.2`).

### Azure side (`infra/modules/onprem-collector.bicep`)
The only Azure resource required is a **role assignment**: the collector VM's
managed identity gets **Monitoring Metrics Publisher** at the VM scope:

```
roleDefinitionId: Monitoring Metrics Publisher (3913510d-42f4-4e42-8a64-420c390055eb)
scope: collector VM
principalId: vm.identity.principalId
```

Telegraf's `azure_monitor` output then:
- auto-detects the **region** and **resource ID** from **IMDS**,
- authenticates with the **managed identity**, and
- writes to custom-metric namespaces **`onprem/snmp`** and **`onprem/interface`**
  attached to the collector VM's resource.

> **Why the collector VM and not the FRR router?** Custom metrics are emitted
> against the *emitter's* resource ID (the box running Telegraf). The polled
> device is distinguished by the `sysName` / `agent_host` **dimension**, not by a
> separate resource.

### Verify (Metrics explorer, not KQL)
Metrics explorer → scope = **collector VM** → namespace `onprem/interface` →
metric `ifInOctets` → split by `ifDescr`. Or via CLI:

```powershell
az monitor metrics list --resource <collector-vm-id> --namespace "onprem/interface" `
  --metric ifInOctets --dimension ifDescr
```

---

## 3. Pipeline 3 — RADIUS AAA audit → Log Analytics

### What it does
Operator SSH logins to the FRR router are authenticated against **FreeRADIUS** on
the collector. FreeRADIUS writes a **who-did-what audit line** (`Login OK` /
`Login incorrect`, *without passwords*) to a flat log, and AMA ships that log into
the custom **`OnPremAAA_CL`** table via a **text-log DCR** — which, unlike Syslog,
**requires a Data Collection Endpoint (DCE)**.

### Flow

```mermaid
sequenceDiagram
    participant U as Operator (ssh netops-oper@frr)
    participant PAM as FRR pam_radius_auth
    participant FR as FreeRADIUS (collector:1812)
    participant LOG as /var/log/freeradius/radius.log
    participant AMA as Azure Monitor Agent
    participant DCE as Data Collection Endpoint
    participant LAW as OnPremAAA_CL

    U->>PAM: SSH login (keyboard-interactive)
    PAM->>FR: RADIUS Access-Request (UDP 1812)
    FR->>FR: check user netops-oper + NAS client onprem-frr
    FR-->>PAM: Access-Accept / Access-Reject
    FR->>LOG: "Auth: Login OK/incorrect [netops-oper] from client onprem-frr"
    Note over FR,LOG: auth=yes, auth_goodpass=no, auth_badpass=no (no secrets)
    AMA->>LOG: tail new lines
    AMA->>DCE: text-log stream (transformKql parses fields)
    DCE->>LAW: Result / Operator / ClientHost / RawData
```

### Device side — RADIUS **client** (`infra/cloud-init/frr-router.yaml`)
The router runs `libpam-radius-auth`, pointed at the collector. The shared secret
is injected by `onprem-router.bicep` via `RADIUS_SECRET_PLACEHOLDER`:

```
# /etc/pam_radius_auth.conf  (server  secret  timeout)
10.100.1.100 RADIUS_SECRET_PLACEHOLDER 3
```

Wiring `pam_radius` into SSH (from `runcmd`):
- `netops-oper` is created as a **local account with its password locked** — so
  the *only* way it can log in is via RADIUS.
- `pam_radius_auth.so` is inserted as the **first, `sufficient`** auth step in
  `/etc/pam.d/sshd` (RADIUS accepts → done; otherwise fall through to local PAM).
- `KbdInteractiveAuthentication yes` in `sshd_config` so SSH will prompt for the
  RADIUS password.

```
auth sufficient pam_radius_auth.so   # prepended to /etc/pam.d/sshd
```

### Collector side — RADIUS **server** (`infra/cloud-init/collector.yaml`)
FreeRADIUS config is **staged to non-conffile paths and copied in `runcmd`** (the
usual conffile-collision avoidance). It defines the NAS client and the operator:

```
# /etc/freeradius/3.0/clients.conf   (localhost + the FRR router as a NAS)
client onprem-frr {
  ipaddr = 10.100.1.201
  secret = RADIUS_SECRET_PLACEHOLDER
  nastype = other
  require_message_authenticator = no
}

# appended to /etc/freeradius/3.0/mods-config/files/authorize
netops-oper Cleartext-Password := "RADIUS_OPERPASS_PLACEHOLDER"
```

Audit logging is enabled **without recording passwords** (edited via `sed` in
`runcmd` on `radiusd.conf`):

```
log {
  auth = yes            # record authentication events
  auth_badpass = no     # do NOT log the (wrong) password
  auth_goodpass = no    # do NOT log the (correct) password
}
```

The resulting audit trail at `/var/log/freeradius/radius.log` looks like:

```
Wed Jul 29 15:39:17 2026 : Auth: (1) Login OK: [netops-oper] (from client onprem-frr port 4819)
Wed Jul 29 15:40:41 2026 : Auth: (4) Login incorrect (...): [netops-oper] (from client onprem-frr port 4908)
```

### Azure side (`infra/modules/onprem-aaa.bicep`)
Custom text logs need **more plumbing than Syslog** — four resources:

```mermaid
flowchart TB
    DCE["Data Collection Endpoint<br/>netsre-onprem-aaa-dce<br/>(REQUIRED for custom text logs)"]
    TBL["Custom table<br/>OnPremAAA_CL<br/>(TimeGenerated, Result, Operator, ClientHost, RawData)"]
    DCR["Text-log DCR<br/>netsre-onprem-aaa-dcr<br/>logFiles → transformKql → table"]
    DCRA["DCR association<br/>→ collector VM (AMA)"]

    DCE --> DCR
    TBL --> DCR
    DCR --> DCRA
```

1. **DCE** (`<prefix>-onprem-aaa-dce`) — mandatory for the Logs Ingestion path
   that custom text logs use.
2. **Custom table** `OnPremAAA_CL` with the parsed schema
   (`Result`, `Operator`, `ClientHost`, `RawData`, plus `TimeGenerated`).
3. **Text-log DCR** — a `logFiles` data source (`filePatterns:
   /var/log/freeradius/radius.log`, `format: text`) feeding a raw
   `Custom-OnPremAAA_CL` stream `{ TimeGenerated, RawData }`, then a
   **`transformKql`** that keeps only auth lines and parses the columns:

   ```kql
   source
   | where RawData has "Login OK" or RawData has "Login incorrect"
   | extend Result = iff(RawData has "Login OK", "Success", "Failure")
   | parse RawData with * "[" Operator "]" *
   | parse RawData with * "from client " ClientHost " port" *
   | project TimeGenerated, Result, Operator, ClientHost, RawData
   ```

4. **DCR association** to the collector VM, so its AMA applies the rule.

> `TimeGenerated` is the **ingestion** time; the device's own clock is preserved
> inside `RawData` for cross-checking.

### Verify

```kql
OnPremAAA_CL
| where TimeGenerated > ago(24h)
| project TimeGenerated, Result, Operator, ClientHost
| order by TimeGenerated desc
```

> ⚠️ **First-ingestion gotcha:** AMA text-log DCRs begin tailing from lines
> **appended after** the DCR association is applied — **pre-existing lines are not
> backfilled**. When validating a new custom-log pipeline, generate fresh events
> *after* the DCR is associated, and allow a few minutes for the first rows.

---

## 4. Cross-cutting concepts

### 4.1 DCR vs DCE — when do you need a DCE?

| Ingestion path | Stream | DCE required? | Used by |
|----------------|--------|--------------|---------|
| Legacy LA agent streams | `Microsoft-Syslog`, perf counters | **No** | Pipeline 1 (Syslog) |
| Logs Ingestion API / custom text logs | `Custom-*_CL` | **Yes** | Pipeline 3 (AAA) |
| Custom metrics | — (not a DCR at all) | **No** | Pipeline 2 (SNMP) |

A **DCR** is the *routing/transform rule*; a **DCE** is the *regional ingestion
endpoint* that the newer Logs Ingestion path posts to. Syslog rides the older path
and skips the DCE; custom text logs cannot.

### 4.2 Logs vs Metrics — two different stores

```mermaid
flowchart LR
    SL["Syslog"] --> LAW[("Log Analytics<br/>KQL")]
    AAA["OnPremAAA_CL"] --> LAW
    SNMP["SNMP via Telegraf"] --> MET[("Azure Monitor Metrics<br/>Metrics explorer")]

    classDef azure fill:#e6f0ff,stroke:#3366cc;
    class LAW,MET azure;
```

- **Logs** = flexible, schema-on-read, queried with **KQL**, higher latency, richer.
- **Metrics** = pre-aggregated numeric time series, low latency, cheap, dimensioned,
  ideal for charts/alerts — but **not** in KQL.

If you later want SNMP data *queryable in KQL alongside syslog*, the alternative is
to point Telegraf at the **Logs Ingestion API** (a `*_CL` table via a DCR+DCE)
instead of `outputs.azure_monitor`. We chose metrics because that is the natural
home for counters like `ifInOctets`.

### 4.3 The cloud-init conffile-collision trap (affects all three)

`cloud-init` `write_files` runs **before** the `apt` package install. If you
pre-write a file that the package ships as a **conffile** (`/etc/snmp/snmpd.conf`,
`/etc/telegraf/telegraf.conf`, FreeRADIUS `clients.conf`, `/etc/pam_radius_auth.conf`),
the install hits a conffile conflict, **half-configures**, and the service silently
keeps its default (or the package user like `_telegraf` is never created).

**Two safe patterns, both used here:**
- **Stage-then-copy:** write to a non-conffile path (e.g. `snmpd.conf.onprem`,
  `clients.onprem.conf`) and `install`/`cp` it into place in `runcmd` *after* the
  package is installed.
- **Drop-in dir:** write into a directory the unit already loads
  (`/etc/telegraf/telegraf.d/`) so the package conffile is untouched.

### 4.4 Secrets & parameterization

The RADIUS shared secret and operator password are **`@secure()` Bicep params**
(`radiusSharedSecret`, `radiusOperatorPassword`), substituted into the cloud-init
via `replace()` (the same mechanism as `COLLECTOR_IP_PLACEHOLDER`). Defaults live
in `deploy-onprem.ps1` (mirroring the `vpnSharedKey` pattern). For production these
belong in **Key Vault**, not script defaults.

### 4.5 Alerting on the telemetry (turning signals into incidents)

The pipelines above only *land* data; alerts make it actionable and give the SRE
Agent an incident to attach a response plan to. Two Bicep modules define them:

**`infra/modules/onprem-log-alerts.bicep`** — an action group `${prefix}-onprem-ag`
plus rules over the ingested data (deployed by the `telemetry` stage):

| Alert | Type | Signal | Sev |
|-------|------|--------|-----|
| `${prefix}-onprem-syslog-critical` | scheduled query | `Syslog` `daemon` facility, severity `critical/alert/emergency` | 2 |
| `${prefix}-onprem-aaa-auth-failures` | scheduled query | `OnPremAAA_CL` where `Result == "Failure"` | 2 |
| `${prefix}-onprem-collector-heartbeat-missing` | scheduled query | `Heartbeat` gap for `Computer == onprem-collector` | 1 |
| `${prefix}-onprem-snmp-uptime-reset` | metric alert | `onprem/snmp` `sysUpTime` drop (device reboot) | 3 |

> Schema gotchas baked into the queries: FRR syslog is the **`daemon`** facility
> with severity strings `error/critical/alert/emergency` (it is `error`, *not*
> `err`); `OnPremAAA_CL` columns have **no `_s` suffix** (`Result`, `Operator`,
> `ClientHost`, `RawData`); Heartbeat only exists for `onprem-collector` (AMA is
> only installed there); `onprem/snmp` has `sysUpTime` but there is **no
> `ifOperStatus`** custom metric.

**`infra/modules/onprem-alerts.bicep`** — metric alerts on a **Connection Monitor**
(`ChecksFailedPercent` / `TestResult`). It is parameterized with a `monitorLabel`
so it can be deployed once per CM without name collisions:

| `monitorLabel` | Targets CM | Produces |
|----------------|-----------|----------|
| `onprem` (default) | `netsre-onprem-connection-monitor` | `${prefix}-onprem-cm-checks-failed` (sev2), `${prefix}-onprem-cm-test-result-fail` (sev1) |
| `clab` | `netsre-clab-connection-monitor` | `${prefix}-clab-cm-checks-failed` (sev2), `${prefix}-clab-cm-test-result-fail` (sev1) |

The `clab` variant is what turns a **containerlab control-plane fault** (a broken
`onprem-r1 ↔ onprem-r2` eBGP session) into a fired Azure alert — see §4.6.

### 4.6 Containerlab traversal Connection Monitor (T3)

`infra/modules/onprem-clab-connection-monitor.bicep` makes control-plane faults
*inside* the containerlab fabric observable from Azure. The clab host VM runs the
**Network Watcher agent** (extension added in `onprem-containerlab.bicep`) and
probes the in-fabric server `172.31.20.10` (ICMP + HTTP:80). The probe path is
`host → onprem-r1 → eBGP → onprem-r2 → server`, and the **return path is also
BGP-dependent** (r1 advertises the host-facing `172.31.11.0/30` into BGP), so
breaking r1↔r2 BGP fails the probe both ways and raises the `clab` CM alerts.
See `infra/containerlab/README.md` → *Relationship to the Azure data path (T3)*
for the veth/route wiring and the baked-cloud-init caveat.

---

## 5. File map

| Concern | File |
|---------|------|
| Device syslog forward + snmpd + PAM RADIUS | `infra/cloud-init/frr-router.yaml` |
| Collector rsyslog + Telegraf + FreeRADIUS | `infra/cloud-init/collector.yaml` |
| Collector VM + AMA + Syslog DCR + Metrics Publisher role | `infra/modules/onprem-collector.bicep` |
| FRR router VM + RADIUS secret param | `infra/modules/onprem-router.bicep` |
| AAA DCE + `OnPremAAA_CL` table + text-log DCR | `infra/modules/onprem-aaa.bicep` |
| Log/metric alerts (syslog, AAA, heartbeat, SNMP) + action group | `infra/modules/onprem-log-alerts.bicep` |
| Connection Monitor metric alerts (parameterized by `monitorLabel`) | `infra/modules/onprem-alerts.bicep` |
| Containerlab-traversal Connection Monitor (T3) | `infra/modules/onprem-clab-connection-monitor.bicep` |
| Containerlab host VM + Network Watcher agent extension | `infra/modules/onprem-containerlab.bicep` |
| Deploy orchestration (`telemetry` / `device` / `aaa` / `containerlab` stages) | `scripts/deploy-onprem.ps1` |

---

## 6. End-to-end deploy & verify

```powershell
# Deploys collector (telemetry), FRR router + LAN + CM (device), and AAA pipeline.
.\scripts\deploy-onprem.ps1 -Stage all

# Generate an audit event, then confirm the AAA pipeline:
#   ssh netops-oper@10.100.1.201   (or: pamtester sshd netops-oper authenticate)
```

Verification queries / views:

| Pipeline | Where | Query |
|----------|-------|-------|
| Syslog | `netsre-law` | `Syslog \| where TimeGenerated > ago(1h)` |
| SNMP | Metrics explorer | scope = collector VM, namespace `onprem/interface` |
| AAA | `netsre-law` | `OnPremAAA_CL \| where TimeGenerated > ago(24h)` |

---

## 7. What the SRE Agent does with this telemetry

Once syslog, SNMP metrics and RADIUS AAA land in Azure Monitor, the **Azure SRE
Agent** reads those signals to investigate incidents and can even run remediation
commands back on the legacy devices. That side of the story — the read path, the
in-VNet executor pattern, and the identity/credential model — is documented
separately to keep this doc focused on the pipelines:

- **[How the SRE Agent consumes on-prem telemetry & closes the loop](./sre-agent-telemetry-and-actuation.md)**
  — what the agent reads, and how actuation (executor + RADIUS authN/authZ) would work.
- **[SRE Agent configuration — how it works](./sre-agent-configuration.md)**
  — how the agent *resource* is configured (incident platform, knowledge base,
  detection model).

---

*Companion docs:*
[SRE Agent — consumes telemetry & closes the loop](./sre-agent-telemetry-and-actuation.md)
· [SRE Agent configuration — how it works](./sre-agent-configuration.md)
· [On-prem simulation & telemetry (design/decisions)](./onprem-network-simulation-and-telemetry.md)
· [Containerlab on-prem — how it works](./containerlab-onprem-how-it-works.md)
