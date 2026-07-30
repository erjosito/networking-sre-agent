# On-Premises Telemetry & Observability (for the SRE Agent)

How on-prem device signals reach Azure Monitor, and the exact queries/metrics the
SRE Agent should use when triaging on-prem incidents. Full internals live in
`docs/onprem-telemetry-pipelines-how-it-works.md`.

All signals land in the Log Analytics workspace **`netsre-law`**
(GUID `04410854-dc8e-48ea-b148-cead76405134`) or in Azure Monitor **custom
metrics** on the collector VM.

---

## Pipelines at a glance

| Signal | Path | Lands in | Query surface |
|--------|------|----------|---------------|
| **Syslog** (FRR/router events) | device rsyslog → collector rsyslog → AMA → DCR | `Syslog` table | KQL |
| **SNMP** (interfaces, uptime) | snmpd → Telegraf (collector) → Azure Monitor | custom metrics | Metrics explorer |
| **RADIUS AAA** (auth/audit) | device PAM → FreeRADIUS (collector) → text-log DCR | `OnPremAAA_CL` table | KQL |
| **Connection Monitor** (reachability) | NW agent probes | `NWConnectionMonitorTestResult` | KQL / metrics |

Only the **collector VM** (`onprem-collector`) runs AMA — it is the single
aggregation point (and a SPOF for the telemetry story).

---

## Query cheat-sheet (exact schema — do not guess column names)

### Syslog (FRR router events)
FRR logs to the **`daemon`** facility. Severity strings are
`error / critical / alert / emergency` — note it is **`error`, not `err`**.

```kusto
Syslog
| where TimeGenerated > ago(1h)
| where Facility == "daemon"
| where SeverityLevel in ("critical","alert","emergency")
| project TimeGenerated, HostName, SeverityLevel, SyslogMessage
```

### RADIUS AAA audit
Table **`OnPremAAA_CL`**. Columns have **no `_s` suffix**:
`Result`, `Operator`, `ClientHost`, `RawData`.

```kusto
OnPremAAA_CL
| where TimeGenerated > ago(24h)
| where Result == "Failure"
| project TimeGenerated, Operator, ClientHost, RawData
```

### Collector heartbeat (is telemetry alive?)
Heartbeat exists **only** for `Computer == "onprem-collector"` (AMA only there).

```kusto
Heartbeat
| where Computer == "onprem-collector"
| summarize LastSeen = max(TimeGenerated)
```

### SNMP custom metrics
- Namespace **`onprem/snmp`**: metric `sysUpTime` (dims `agent_host`, `host`,
  `sysName`). A drop/reset ⇒ device reboot.
- Namespace **`onprem/interface`**: `ifInOctets`, `ifOutOctets` (dims
  `agent_host`, `host`, `ifDescr`).
- **There is no `ifOperStatus` metric** — do not query for it.

Scope = the **collector VM** resource; view in Metrics explorer (not KQL).

### Connection Monitor results
```kusto
NWConnectionMonitorTestResult
| where TimeGenerated > ago(1h)
| where TestGroupName in ("clabhost-to-infabric-server","onprem-to-webapp")
| summarize passed=countif(TestResult == "Pass"),
            failed=countif(TestResult == "Fail")
    by TestGroupName, bin(TimeGenerated, 5m)
```

---

## Alerts already deployed (what fires an incident)

Action group **`netsre-onprem-ag`**. See `infra/modules/onprem-log-alerts.bicep`
and `infra/modules/onprem-alerts.bicep`.

| Alert | Type | Fires on | Sev |
|-------|------|----------|-----|
| `netsre-onprem-syslog-critical` | log query | FRR `daemon` syslog sev `critical/alert/emergency` | 2 |
| `netsre-onprem-aaa-auth-failures` | log query | `OnPremAAA_CL` `Result == "Failure"` | 2 |
| `netsre-onprem-collector-heartbeat-missing` | log query | Heartbeat gap for `onprem-collector` | 1 |
| `netsre-onprem-snmp-uptime-reset` | metric | `onprem/snmp` `sysUpTime` drop (reboot) | 3 |
| `netsre-onprem-cm-checks-failed` | metric | onprem VPN-path CM checks failed | 2 |
| `netsre-onprem-cm-test-result-fail` | metric | onprem VPN-path CM test result fail | 1 |
| `netsre-clab-cm-checks-failed` | metric | **containerlab** CM checks failed (r1↔r2 fault) | 2 |
| `netsre-clab-cm-test-result-fail` | metric | containerlab CM test result fail | 1 |

---

## Triage flow when an on-prem alert fires

1. **Identify the layer** — VPN-path (`onprem-*`) vs containerlab fabric (`clab-*`).
2. **Correlate reachability** with `NWConnectionMonitorTestResult` for the failing
   test group.
3. **Check the control plane** — for a `clab-*` alert, inspect BGP/OSPF on the
   fabric (see the BGP and OSPF runbooks).
4. **Check device health** — SNMP `sysUpTime` (reboot?), Syslog `daemon`
   critical events around the alert time.
5. **Check the collector** — if Heartbeat is missing, telemetry itself is down and
   other "green" signals are stale, not healthy.
6. **Check audit** — `OnPremAAA_CL` failures near the incident may indicate a
   change/lockout.
