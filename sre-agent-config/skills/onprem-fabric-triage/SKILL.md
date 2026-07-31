# On-Prem Fabric Triage (Containerlab)

Use this skill when an **on-premises** incident fires — any alert whose name
starts with `netsre-onprem-*` or `netsre-clab-*`, or any Connection Monitor
failure in the `clabhost-to-infabric-server` / `onprem-to-webapp` test groups.

Unlike the Azure hub-spoke faults (which the network-expert already knows), the
on-prem fabric is a **Containerlab FRR network** you must reason about at the
**control-plane** level. Device telemetry flowing (SNMP/Heartbeat/syslog present)
does **NOT** mean the control plane is healthy — an OSPF or BGP fault can break
reachability while every "is-it-alive" signal stays green. **Do not conclude the
device is healthy just because it is still sending telemetry.**

---

## The fabric (ground truth)

Everything runs inside one Azure VM, **`netsre-onprem-clab`** (10.100.1.5), as
Docker containers:

```
onprem-host ── 172.31.20.0/24 (LAN) ── onprem-r2 ══ eBGP over loopbacks ══ onprem-r1 ── 172.31.11.0/30 ── (Azure probe)
 172.31.20.10                          AS65102       (OSPF area 0 underlay)   AS65101
 (HTTP :80)                            lo 10.99.2.2   172.31.12.0/30 transit   lo 10.99.1.1
```

- Containers: `clab-onprem-onprem-r1`, `clab-onprem-onprem-r2`, `clab-onprem-onprem-host`.

> **Two misdirections to avoid (they waste the whole investigation):**
> 1. **The clab CM alert's SOURCE endpoint IS `netsre-onprem-clab` (10.100.1.5)** —
>    that *same* VM hosts the FRR routers as Docker containers. So run the Step-3
>    protocol checks **there**, via `az vm run-command` + `docker exec
>    clab-onprem-onprem-r1 vtysh -c '…'`. Plain `vtysh`/`vtysh not found` on the
>    host is expected — the routing daemons live **inside the containers**, not on
>    the host. Never conclude "no BGP speaker here" from a missing host `vtysh`.
> 2. **`netsre-onprem-frr` (10.100.1.201) is a DIFFERENT VM** — the Stage-1
>    router-on-a-stick, frequently **deallocated**, and **NOT** in the clab probe
>    path (`host veth clabr1host → clab-onprem-onprem-r1 → r2 → onprem-host`). A
>    deallocated `netsre-onprem-frr` is a **red herring** for any `netsre-clab-*`
>    alert — do **not** recommend starting it to fix a clab CM failure.

> **Route ownership is DETERMINISTIC — do not "investigate who advertises what":**
> - **`172.31.20.0/24` (host `172.31.20.10`) is ALWAYS originated by `onprem-r2`**
>   (AS65102, `network 172.31.20.0/24`); `onprem-r1` learns it via eBGP, recursive
>   over the OSPF loopback `10.99.2.2`. The answer to "which side should advertise
>   172.31.20.10" is **always r2** — never treat it as an open question.
> - **The clab CM does NOT traverse the Azure VPN.** The probe goes
>   `netsre-onprem-clab host → veth clabr1host (172.31.11.1) → r1 → r2 → host`. It
>   never touches the on-prem/hub VPN gateways. So **VPN gateway learned/advertised
>   routes are IRRELEVANT** to a `netsre-clab-*` alert, and `172.31.20.0/24` is
>   *not supposed* to appear on any gateway. Do **not** inspect gateway BGP or
>   conclude a fault from "the gateway doesn't learn the LAN" — it never should.
> - The real question is only **"why has r2's `172.31.20.0/24` stopped reaching
>   r1/the host"** → OSPF adjacency down? BGP session down? prefix filtered? Go
>   straight to `docker exec clab-onprem-onprem-r1 vtysh -c 'show ip ospf neighbor'`.
- **OSPF** (area 0, over the transit) is the **IGP underlay**. It carries **only
  the loopbacks** `10.99.1.1/32`, `10.99.2.2/32`.
- **BGP** peers **loopback-to-loopback** (`update-source lo`, `ebgp-multihop 2`)
  and carries the **data path**: r2 originates the LAN `172.31.20.0/24`; r1
  originates the return `172.31.11.0/30`. On r1 the LAN route is **recursive over
  the OSPF-learned peer loopback `10.99.2.2`**.
- **CASCADE:** BGP rides the OSPF-learned loopbacks, so an **OSPF adjacency fault
  withdraws the peer loopback → the BGP session drops → the LAN is withdrawn → the
  clab Connection Monitor fails.** OSPF is the root cause but the first data-plane
  symptom is a CM failure + a `bgpd` "neighbor Down" syslog. **Trace a BGP-down
  symptom back to OSPF** rather than stopping at BGP.

### Blast radius — decide which plane is the ROOT CAUSE (both fail the CM now)

Because BGP peers over the OSPF-learned loopbacks, **every** control-plane fault
here — OSPF *or* BGP *or* the transit link — ultimately withdraws the LAN and
fires the clab Connection Monitor. The job is to find the **root layer**, not just
to note "the LAN is down".

| Root cause | Cascade | Discriminator (OSPF adjacency state) | Which alert fires |
|------------|---------|--------------------------------------|-------------------|
| **OSPF** (area/MTU/network-type) | adj down → peer loopback withdrawn → BGP session drops → LAN withdrawn | `show ip ospf neighbor` **empty/stuck**; `O 10.99.2.2/32` **gone** | `netsre-clab-cm-*` **and** `ospfd`/`bgpd` syslog |
| **BGP** (session shut / policy) | session/route down → LAN withdrawn | OSPF neighbor **Full**, `O 10.99.2.2/32` **present** | `netsre-clab-cm-*` + `bgpd` syslog |
| **Transit link** down | OSPF **and** BGP both drop | adjacency gone **and** `eth1` down | `netsre-clab-cm-*` |

> **Key discriminator:** a clab **CM** failure with a `bgpd` "neighbor Down"
> syslog is **ambiguous** — check the **OSPF adjacency first**. If OSPF is
> **empty** and `O 10.99.2.2/32` is **gone**, the BGP drop is a *symptom* and the
> **root cause is OSPF**. If OSPF is **Full** and the peer loopback is present, the
> root cause is genuinely **BGP** (session shut or a route policy). Let the alert's
> `ProcessName` dimension (`ospfd` vs `bgpd` vs `zebra`) corroborate.

---

## Targeted triage procedure

### Step 1 — Read the EXACT triggering signal (never skip this)

Do not start from generic health. Pull the specific rows that fired the alert.

**Syslog alert** (`netsre-onprem-syslog-critical`) — use the `HostName` and
`ProcessName` carried on the alert, then read the message body:

```kusto
Syslog
| where TimeGenerated between (ago(20m) .. now())
| where Facility == "daemon"
| where SeverityLevel in ("error","critical","alert","emergency")
| project TimeGenerated, HostName, ProcessName, SeverityLevel, SyslogMessage
| order by TimeGenerated desc
```

The message text is the strongest lead (e.g. `OSPF: nbr 10.99.2.2 down`,
`bgp neighbor 172.31.12.2 went from Established to Idle`, interface down). **Quote
the actual message in your investigation** and let it target Steps 2–3.

**Connection Monitor alert** (`clab-*`) — confirm scope and timing:

```kusto
NWConnectionMonitorTestResult
| where TimeGenerated > ago(30m)
| where TestGroupName == "clabhost-to-infabric-server"
| summarize passed=countif(TestResult=="Pass"), failed=countif(TestResult=="Fail")
    by bin(TimeGenerated, 1m)
| order by TimeGenerated desc
```

### Step 2 — Identify the implicated device + subsystem + fault class

From the syslog message / alert dimensions decide: which **device** (r1 or r2),
which **subsystem** (`ospfd` / `bgpd` / `zebra`/kernel), and whether the symptom is
an **adjacency/session down**, a **stuck adjacency**, or a **route missing while
the session/adjacency is up** (a policy fault). Map it to the fault table below.

### Step 3 — Run exploratory control-plane commands on the device AND its neighbor

Reachability alone is not enough — inspect protocol state on **both** ends of the
transit. Run read-only commands on the clab VM (see "Running commands" below):

```bash
R1=clab-onprem-onprem-r1; R2=clab-onprem-onprem-r2
# OSPF FIRST — it underpins BGP, so rule it in/out before blaming BGP
docker exec $R1 vtysh -c 'show ip ospf neighbor'          # healthy = Full
docker exec $R1 vtysh -c 'show ip ospf interface eth1'    # area / net-type / MTU
docker exec $R2 vtysh -c 'show ip ospf interface eth1'    # compare against R1
docker exec $R1 vtysh -c 'show ip route 10.99.2.2'        # peer loopback via OSPF? (gone ⇒ OSPF root cause)
# BGP (peers over the loopback 10.99.2.2)
docker exec $R1 vtysh -c 'show ip bgp summary'            # healthy = Established, PfxRcd 1
docker exec $R1 vtysh -c 'show ip route 172.31.20.0/24'   # LAN present (recursive via 10.99.2.2)?
docker exec $R2 vtysh -c 'show ip bgp neighbor 10.99.1.1 advertised-routes'  # is r2 advertising the LAN?
# link + data path
docker exec $R1 vtysh -c 'show interface eth1'
docker exec $R1 ping -c2 172.31.20.10
```

Key discriminators:
- **OSPF neighbor empty + `10.99.2.2/32` gone** ⇒ **OSPF is the root cause**; any
  BGP-down you also see is a *downstream symptom* of the withdrawn loopback.
- **OSPF Full + peer loopback present, but BGP not Established** ⇒ genuine **BGP
  session** fault (e.g. neighbor shut).
- **BGP `Established` but the LAN is absent** ⇒ the route is being withdrawn or
  **filtered** (missing `network` statement or an outbound route-map) — check
  `advertised-routes` on **r2**, not just session state on r1.

### Step 4 — Check recent changes on the device AND its neighbors

Faults are usually caused by a change. Correlate around the incident time:

- **Config drift** — compare live config to the committed source of truth
  `infra/containerlab/configs/{r1,r2}/frr.conf`:
  ```bash
  docker exec $R1 vtysh -c 'show running-config'
  docker exec $R2 vtysh -c 'show running-config'
  ```
- **Login / admin activity** — RADIUS AAA audit (who logged into a device recently):
  ```kusto
  OnPremAAA_CL
  | where TimeGenerated > ago(6h)
  | project TimeGenerated, Result, Operator, ClientHost, RawData
  | order by TimeGenerated desc
  ```
- **Syslog history** on both devices (not just the triggering line) for flaps
  leading up to the alert — widen the `Syslog` query window and drop the severity
  filter to see `notice`/`info` adjacency/session transitions.
- **Reboot?** SNMP `sysUpTime` (namespace `onprem/snmp`) dropping = a device
  restarted (config could have reloaded from `frr.conf`).

### Step 5 — Confirm the collector is alive before trusting "green"

If `netsre-onprem-collector-heartbeat-missing` is active, **telemetry itself is
down** and other green signals are stale, not healthy:

```kusto
Heartbeat | where Computer == "onprem-collector" | summarize LastSeen = max(TimeGenerated)
```

### Step 6 — Remediate, then verify recovery

Apply the fix from the fault table, then re-run the Step-3 checks AND the CM query
until protocol state is `Full`/`Established`, the LAN route is back, and the CM
passes. Live `vtysh` edits are **not persisted** — for a durable fix, update
`infra/containerlab/configs/{r1,r2}/frr.conf`.

---

## Fault catalogue (every injectable containerlab fault)

Each is injectable via `scripts/inject-fault.ps1 -Scenario <name> [-Revert]`.

| Scenario | Device / subsystem | First signal | Targeted confirmation | Root cause → fix |
|----------|--------------------|--------------|-----------------------|------------------|
| `clab-ospf-area-mismatch` | r1 / ospfd (→ cascades to bgpd) | **clab CM fails** + `ospfd`/`bgpd` syslog | `show ip ospf neighbor` empty; `O 10.99.2.2/32` gone; **then** BGP peer 10.99.2.2 Connect/Active | transit in wrong area → set both to `area 0` |
| `clab-ospf-mtu-mismatch` | r1 / ospfd (→ cascade) | **clab CM fails** + syslog | neighbor stuck `ExStart/Exchange`; `show interface eth1` MTU differs; loopback withdrawn → BGP down | interface MTU mismatch → match MTU (1500) |
| `clab-ospf-network-type-mismatch` | r1 / ospfd (→ cascade) | **clab CM fails** + syslog | neighbor never `Full`; `show ip ospf interface eth1` Network Type differs; loopback withdrawn → BGP down | net-type differs → set both `point-to-point` |
| `clab-bgp-session-down` | r1 / bgpd | **clab CM fails**; syslog `bgpd` Established→Idle | OSPF **Full** + `O 10.99.2.2/32` present; `show ip bgp summary` peer Idle(Admin); LAN "% Network not in table" | neighbor administratively shut → `no neighbor 10.99.2.2 shutdown` |
| `clab-lan-route-withdraw` | r2 / bgpd | **clab CM fails**; session stays up | OSPF Full; `show ip bgp summary` **Established** but no LAN on r1 | r2 missing `network 172.31.20.0/24` → re-add it |
| `clab-bgp-prefix-filter` | r2 / bgpd | **clab CM fails**; session stays up | r2 `advertised-routes` to r1 **empty** for the LAN; outbound route-map present | outbound route-map denies LAN → remove `route-map RM-DENY-LAN` / neighbor `... out` |
| `clab-transit-link-down` | r1 / zebra+kernel | **clab CM fails**; OSPF **and** BGP both drop | `show interface eth1` down; both neighbor/session down | transit link down → `ip link set eth1 up` |

**All** of these fail the clab CM (the LAN is withdrawn either directly or via the
OSPF→BGP cascade). Distinguish the **root layer** by OSPF adjacency state **first**:
OSPF **empty + `10.99.2.2/32` gone** ⇒ an **OSPF** root cause (the BGP-down you also
see is a symptom); OSPF **Full** ⇒ a genuine **BGP** fault — then split it by
whether the session is **Established** (route-missing / prefix-filter, check r2's
`advertised-routes`) or **down** (session-down / link-down).

---

## Running commands on the fabric

The routers are FRR containers on `netsre-onprem-clab`. From an `az vm run-command`
context, **base64-encode** the bash and decode it on the VM (raw multi-layer
quoting gets corrupted). For **configuration** changes, feed a **heredoc into
`vtysh`** — a single `vtysh` invocation with multiple `-c 'configure terminal' -c …`
flags does **not** reliably stay in config mode and silently fails to commit
route-maps / prefix-lists / neighbor policy:

```bash
# read-only is fine with -c
docker exec clab-onprem-onprem-r1 vtysh -c 'show ip ospf neighbor'

# configuration MUST use a heredoc (config-file semantics)
docker exec -i clab-onprem-onprem-r2 vtysh <<'EOF'
configure terminal
router bgp 65102
 address-family ipv4 unicast
  network 172.31.20.0/24
end
EOF
```

Prefer `scripts/inject-fault.ps1` (which already encodes this correctly) for
inject/revert during demos and validation.

---

## References

- `knowledge/onprem-network-topology.md` — full node/interface/AS ground truth
- `knowledge/onprem-telemetry-and-observability.md` — exact KQL/metric schema
- `knowledge/onprem-ospf-fault-runbook.md` — OSPF deep dive
- `knowledge/onprem-bgp-fault-runbook.md` — BGP deep dive
