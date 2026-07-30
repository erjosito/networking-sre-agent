# Runbook — On-Prem OSPF Misconfiguration (Containerlab)

**Scope:** the on-prem Containerlab fabric inside `netsre-onprem-clab`
(10.100.1.5). See `knowledge/onprem-network-topology.md`.

**What OSPF does here:** OSPF is the on-prem **IGP**. It runs in **area 0** over
the `onprem-r1 ↔ onprem-r2` transit link `172.31.12.0/30` (configured as
`point-to-point`) and carries the router **loopbacks** (`10.99.1.1/32`,
`10.99.2.2/32`). The loopbacks are advertised **only via OSPF** — *not* BGP — so
an OSPF fault is isolated from the BGP-carried data path.

> **Design note (blast radius):** BGP still carries the on-prem LAN
> `172.31.20.0/24`, so an OSPF-only fault breaks **internal / management
> reachability** (router-to-router loopbacks) **without** taking down the LAN data
> path or the `netsre-clab-connection-monitor` probe. This models a very common
> real-world situation: an IGP misconfig that a data-plane health check does *not*
> catch — exactly the kind of "silent" fault the SRE Agent should reason about by
> combining control-plane state with syslog, not reachability alone.

---

## Typical OSPF misconfigurations to simulate

| Misconfig | Effect | How to inject (r1) |
|-----------|--------|--------------------|
| **Area mismatch** | Adjacency never reaches Full; loopbacks withdrawn | put transit in a different area than the peer |
| **Network-type mismatch** | Hello/adjacency fails on the segment | `ip ospf network broadcast` on one side only |
| **MTU mismatch** | Stuck in `ExStart/Exchange` | change interface MTU on one side |
| **Wrong/duplicate router-id** | Adjacency flaps or LSDB confusion | set both routers to the same `ospf router-id` |
| **Missing `network` statement** | Interface not in OSPF; no adjacency | remove the transit `network ... area 0` |

The example below uses the **area mismatch** (the most common and cleanest to
demonstrate).

---

## Step 0 — read the triggering signal first

Before probing, pull the **exact syslog rows** that fired the alert (the
`netsre-onprem-syslog-critical` alert now carries `HostName` + `ProcessName`
dimensions, so it names the device and daemon):

```kusto
Syslog
| where TimeGenerated > ago(20m)
| where Facility == "daemon"
| where SeverityLevel in ("error","critical","alert","emergency")
| project TimeGenerated, HostName, ProcessName, SeverityLevel, SyslogMessage
| order by TimeGenerated desc
```

Quote the actual message (e.g. `OSPF: nbr 10.99.2.2 down`) and let it target the
device + interface you inspect below. Then check **recent changes on that device
AND its neighbor**: compare live `show running-config` to
`infra/containerlab/configs/{r1,r2}/frr.conf`, and review `OnPremAAA_CL` logins in
the last 6h.

## Diagnosis (run on the clab VM)

> Use `az vm run-command` with a **base64-encoded** bash script; multi-`-c`
> `docker exec`/`vtysh` quoting is otherwise corrupted. Use
> `vtysh -c 'configure terminal'`, never `conf t`. **Read-only** `show` commands
> work with a single `-c`; **configuration** changes must use a **heredoc into
> `vtysh`** (a single vtysh call with multiple `-c 'configure terminal' -c …` flags
> does NOT stay in config mode and silently fails to commit).

```bash
R1=clab-onprem-onprem-r1; R2=clab-onprem-onprem-r2

# 1. Adjacency state — healthy is Full (point-to-point, no DR on a /30)
docker exec $R1 vtysh -c 'show ip ospf neighbor'

# 2. Interface OSPF params — area, network type, MTU, hello/dead timers
docker exec $R1 vtysh -c 'show ip ospf interface eth1'
docker exec $R2 vtysh -c 'show ip ospf interface eth1'

# 3. OSPF-learned routes — peer loopback should be present as 'O'
docker exec $R1 vtysh -c 'show ip route ospf'          # expect O 10.99.2.2/32
docker exec $R2 vtysh -c 'show ip route ospf'          # expect O 10.99.1.1/32

# 4. Reachability that DEPENDS on OSPF (loopback-to-loopback)
docker exec $R1 ping -c2 -I 10.99.1.1 10.99.2.2
```

Interpretation:
- Neighbor **empty / stuck in Init/ExStart** ⇒ adjacency fault. Compare
  `show ip ospf interface eth1` on both sides — mismatched **Area**, **Network
  Type**, **MTU**, or **timers** is the usual cause.
- Neighbor **Full** but peer loopback missing ⇒ missing `network` / redistribution.
- Loopback ping fails while `172.31.20.0/24` (BGP) still works ⇒ confirms an
  **OSPF-only** (IGP) fault; the CM will (correctly) stay green.

### Correlate in Azure Monitor

FRR logs OSPF adjacency changes to the **`daemon`** syslog facility, forwarded to
`netsre-law`:

```kusto
Syslog
| where TimeGenerated > ago(1h)
| where Facility == "daemon"
| where SyslogMessage has "OSPF" or SyslogMessage has "Nbr"
| project TimeGenerated, HostName, SeverityLevel, SyslogMessage
```

---

## Reproduce the fault (area mismatch)

Preferred: `scripts/inject-fault.ps1 -Scenario clab-ospf-area-mismatch`
(and `-Revert` to undo). It encodes the change correctly. Manual equivalent —
note the **heredoc** (not multiple `-c` flags):

```bash
docker exec -i clab-onprem-onprem-r1 vtysh <<'EOF'
configure terminal
router ospf
 no network 172.31.12.0/30 area 0
 network 172.31.12.0/30 area 1
end
EOF
```

Expected (~within dead interval, ≤40s): `show ip ospf neighbor` on r1 becomes
**empty**; `O 10.99.2.2/32` disappears from r1's route table; loopback ping fails.
The BGP session and `172.31.20.0/24` are **unaffected**.

## Remediate / revert

`scripts/inject-fault.ps1 -Scenario clab-ospf-area-mismatch -Revert`, or manually:

```bash
docker exec -i clab-onprem-onprem-r1 vtysh <<'EOF'
configure terminal
router ospf
 no network 172.31.12.0/30 area 1
 network 172.31.12.0/30 area 0
end
EOF
```

Confirm: `show ip ospf neighbor` returns to **Full**; `O 10.99.2.2/32` reappears;
loopback ping succeeds.

> **Verified live** on `netsre-onprem-clab`: adjacency Full → area mismatch →
> neighbor table empty → revert → Full, with BGP/CM untouched throughout.

---

## Notes

- Committed config: `infra/containerlab/configs/{r1,r2}/frr.conf` (OSPF area 0 on
  the transit, loopbacks in OSPF) and `.../daemons` (`ospfd=yes`). Changes apply on
  a **fresh fabric deploy / redeploy** — see the baked-cloud-init caveat in
  `infra/containerlab/README.md`. Runtime `vtysh` edits are not persisted.
- The transit is `ip ospf network point-to-point`, so a healthy adjacency is
  **Full** with no DR/BDR election.
