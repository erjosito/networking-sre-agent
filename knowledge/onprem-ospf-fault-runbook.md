# Runbook — On-Prem OSPF Misconfiguration (Containerlab)

**Scope:** the on-prem Containerlab fabric inside `netsre-onprem-clab`
(10.100.1.5). See `knowledge/onprem-network-topology.md`.

**What OSPF does here:** OSPF is the on-prem **IGP underlay**. It runs in
**area 0** over the `onprem-r1 ↔ onprem-r2` transit link `172.31.12.0/30`
(configured as `point-to-point`) and carries the router **loopbacks**
(`10.99.1.1/32`, `10.99.2.2/32`), advertised **only via OSPF** — not BGP. **BGP
peers over those loopbacks** (`update-source lo`, `ebgp-multihop 2`), so BGP is
reliant on the OSPF underlay to reach its neighbor.

> **Design note (blast radius — CASCADE):** because the eBGP session is
> loopback-to-loopback and the loopbacks are only reachable via OSPF, an OSPF
> adjacency fault **cascades**: the peer loopback is withdrawn → the BGP session
> (which peers over it) drops → the on-prem LAN `172.31.20.0/24` is withdrawn in
> both directions → the `netsre-clab-connection-monitor` probe **fails** and
> `netsre-clab-cm-*` fires. The **root cause is OSPF**, but the **first data-plane
> symptom is a Connection-Monitor failure** (and a `bgpd` "neighbor Down" syslog).
> This models a real WAN "IGP underlay + BGP over loopbacks" fabric: an IGP fault
> that a naïve triage would misattribute to BGP. The SRE Agent must trace the
> cascade back to OSPF — do **not** stop at "the BGP session is down"; check the
> OSPF adjacency and the missing peer-loopback route.

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

# 4. The CASCADE — BGP peers over the loopback, LAN rides BGP
docker exec $R1 vtysh -c 'show ip bgp summary'         # peer 10.99.2.2 Established?
docker exec $R1 vtysh -c 'show ip route 172.31.20.0/24'  # LAN present (recursive via 10.99.2.2)?

# 5. Reachability that DEPENDS on OSPF (loopback-to-loopback)
docker exec $R1 ping -c2 -I 10.99.1.1 10.99.2.2
```

Interpretation:
- Neighbor **empty / stuck in Init/ExStart** ⇒ adjacency fault. Compare
  `show ip ospf interface eth1` on both sides — mismatched **Area**, **Network
  Type**, **MTU**, or **timers** is the usual cause.
- Neighbor **Full** but peer loopback missing ⇒ missing `network` / redistribution.
- Peer loopback `O 10.99.2.2/32` **gone** ⇒ the **cascade** is in play: the BGP
  session (peered over that loopback) will drop within `timers 3 9` and
  `172.31.20.0/24` disappears from r1 (`% Network not in table`) ⇒ the CM fails.
  When you see a `bgpd` "neighbor Down" symptom, **do not stop there** — confirm
  the OSPF adjacency and the missing `O 10.99.2.2/32` route to reach the true root
  cause (OSPF), not the downstream BGP symptom.

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

Expected (~within dead interval, ≤8s): `show ip ospf neighbor` on r1 becomes
**empty**; `O 10.99.2.2/32` disappears from r1's route table; loopback ping fails.
Then the **cascade** (~within BGP `timers 3 9`): the r1↔r2 BGP session (peered over
`10.99.2.2`) drops to `Connect/Active`, `172.31.20.0/24` becomes
**"% Network not in table"** on r1, the host probe to `172.31.20.10` goes to 100%
loss, and `netsre-clab-connection-monitor` fails → `netsre-clab-cm-*` fires. Total
convergence ~15s.

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
loopback ping succeeds; the BGP session re-establishes over the loopback;
`172.31.20.0/24` returns to r1; the CM recovers.

> **Verified live** on `netsre-onprem-clab`: adjacency Full → area mismatch →
> neighbor table empty → **BGP peer 10.99.2.2 drops to Connect** → LAN
> `172.31.20.0/24` "% Network not in table" → host probe 100% loss; revert →
> Full → BGP re-established → LAN restored → probe passes.

---

## Notes

- Committed config: `infra/containerlab/configs/{r1,r2}/frr.conf` (OSPF area 0 on
  the transit, loopbacks in OSPF) and `.../daemons` (`ospfd=yes`). Changes apply on
  a **fresh fabric deploy / redeploy** — see the baked-cloud-init caveat in
  `infra/containerlab/README.md`. Runtime `vtysh` edits are not persisted.
- The transit is `ip ospf network point-to-point`, so a healthy adjacency is
  **Full** with no DR/BDR election.
