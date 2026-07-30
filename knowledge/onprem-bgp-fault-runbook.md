# Runbook — Containerlab BGP Fault (r1 ↔ r2)

**Scope:** the on-prem Containerlab fabric inside `netsre-onprem-clab` (10.100.1.5).
See `knowledge/onprem-network-topology.md` for the full topology.

**Symptom / trigger:** `netsre-clab-cm-checks-failed` or
`netsre-clab-cm-test-result-fail` fires; the `clabhost-to-infabric-server`
Connection Monitor test group shows 100% loss / HTTP failures.

---

## Why this happens

The on-prem LAN `172.31.20.0/24` (where `onprem-host` lives) is reachable **only**
because `onprem-r2` advertises it into eBGP (AS65102) and `onprem-r1` (AS65101)
accepts it. `onprem-r1` in turn advertises the host-facing `172.31.11.0/30` so the
**return path is also BGP-dependent**. Therefore **any** fault on the
`onprem-r1 ↔ onprem-r2` eBGP session or the transit link `172.31.12.0/30`
withdraws the route in *both* directions and fails the CM probe.

Common root causes: BGP session down (neighbor unreachable / shutdown), transit
link down, `network` statement removed, route-map/prefix-list filtering, or an
AS-path/`ebgp-requires-policy` misconfiguration.

---

## Diagnosis (run on the clab VM)

> Use `az vm run-command` with a **base64-encoded** bash script; multi-`-c`
> `docker exec`/`vtysh` quoting is otherwise corrupted (it has previously executed
> unintended host commands). Use `vtysh -c 'configure terminal'`, not `conf t`.

```bash
# 1. BGP session state (want: Established)
docker exec clab-onprem-onprem-r1 vtysh -c 'show ip bgp summary'
docker exec clab-onprem-onprem-r2 vtysh -c 'show ip bgp summary'

# 2. Is the LAN prefix present on r1?  (want: 172.31.20.0/24 via 172.31.12.2)
docker exec clab-onprem-onprem-r1 vtysh -c 'show ip route 172.31.20.0/24'

# 3. Is the return prefix present on r2? (want: 172.31.11.0/30 via 172.31.12.1)
docker exec clab-onprem-onprem-r2 vtysh -c 'show ip route 172.31.11.0/30'

# 4. Transit link up?
docker exec clab-onprem-onprem-r1 vtysh -c 'show interface eth1'

# 5. Data-path check end to end
docker exec clab-onprem-onprem-r1 ping -c2 172.31.20.10
```

Interpretation:
- BGP **not** Established + no LAN route on r1 ⇒ control-plane fault (session/link).
- BGP Established but **no** `172.31.20.0/24` ⇒ r2 stopped advertising it
  (missing `network` statement or filtering).
- LAN route present but ping fails ⇒ data-plane / forwarding issue (`ip_forward`,
  interface down on r2/host).

---

## Reproduce the fault (demo / test)

Break the BGP session by shutting the neighbor on r1:

```bash
docker exec clab-onprem-onprem-r1 vtysh -c 'configure terminal' \
  -c 'router bgp 65101' -c 'neighbor 172.31.12.2 shutdown'
```

Expected: `show ip route 172.31.20.0/24` on r1 → *"% Network not in table"*;
CM probe → 100% loss; `netsre-clab-cm-checks-failed` fires within the alert window.

## Remediate / revert

```bash
docker exec clab-onprem-onprem-r1 vtysh -c 'configure terminal' \
  -c 'router bgp 65101' -c 'no neighbor 172.31.12.2 shutdown'
```

Confirm recovery: `show ip bgp summary` → Established; `show ip route
172.31.20.0/24` returns; CM test passes again (icmp + http:80).

---

## Notes

- The committed FRR config (`infra/containerlab/configs/r1/frr.conf`,
  `r2/frr.conf`) is the source of truth; live vtysh changes are **not** persisted
  and are lost on `containerlab destroy`/redeploy.
- CRLF line endings break `/etc/frr/daemons`; the repo pins LF via `.gitattributes`
  for `infra/containerlab/configs/**`.
