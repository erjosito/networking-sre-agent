# On-Premises Network Topology (Simulated)

This document describes the **simulated on-premises network** attached to the
`netsre` Azure lab. The SRE Agent should treat this as the ground-truth topology
when triaging on-prem connectivity, routing, or control-plane incidents.

There are **two layers** to the on-prem simulation:

1. An **Azure-hosted on-prem VNet** connected to the Azure hubs over S2S VPN
   (this is what Azure sees and routes to).
2. A **Containerlab fabric** running *inside* one VM of that VNet, providing a
   high-fidelity multi-router control plane (FRRouting) for realistic
   device-level faults.

---

## Layer 1 — Azure-hosted on-prem VNet

| Item | Value |
|------|-------|
| VNet address space | `10.100.0.0/16` |
| VPN Gateway | route-based, **BGP ASN 65100** |
| Connected to | Hub1 VPN GW (ASN 65001) and Hub2 VPN GW (ASN 65002) via S2S + BGP |
| On-prem "server"/probe VM | in the `default` subnet (`10.100.1.0/24`) |
| FRR router-on-a-stick (Stage 1) | `10.100.1.201` |
| Telemetry **collector** VM | `10.100.1.100` (rsyslog + AMA + Telegraf + FreeRADIUS) |
| On-prem **LAN** subnet (Stage 1) | `10.100.2.0/24` (behind the FRR router) |
| Containerlab **host** VM | `netsre-onprem-clab` at `10.100.1.5` |

The on-prem VNet reaches Azure spokes (`10.11/12/21/22.0.0/16`) via BGP over the
VPN; the hubs learn `10.100.0.0/16` from the on-prem gateway.

---

## Layer 2 — Containerlab fabric (inside `netsre-onprem-clab`, 10.100.1.5)

A containerized fabric (`infra/containerlab/onprem.clab.yml`) modelling a small
two-tier on-prem site. Nodes run **FRRouting 9.1** (`quay.io/frrouting/frr`).

```
                    172.31.11.0/30 (host-facing probe link)
   Azure lab-host VM ────────────── onprem-r1 (WAN edge)
   veth clabr1host                   eth2 .2   │ lo 10.99.1.1/32
   .1                                          │ eth1 172.31.12.1/30
                                               │
                                OSPF area 0 (IGP underlay, carries loopbacks)
                                     eBGP over loopbacks (multihop)
                                     AS65101 ⇄ AS65102
                                               │  172.31.12.0/30 transit
                                               │
                                     onprem-r2 (core) eth1 172.31.12.2/30
                                     lo 10.99.2.2/32
                                     eth2 172.31.20.1/24  (on-prem LAN)
                                               │
                                     onprem-host  172.31.20.10/24 (HTTP :80)
```

### Node facts

| Node | Role | Loopback | Interfaces | Routing |
|------|------|----------|------------|---------|
| `onprem-r1` | WAN edge | `10.99.1.1/32` | `eth1 172.31.12.1/30` (transit), `eth2 172.31.11.2/30` (host probe) | **OSPF area 0** on transit (carries loopbacks); **BGP AS65101** peers r2 loopback `10.99.2.2` (`update-source lo`, `ebgp-multihop 2`); advertises `172.31.11.0/30` into BGP |
| `onprem-r2` | Core | `10.99.2.2/32` | `eth1 172.31.12.2/30` (transit), `eth2 172.31.20.1/24` (LAN) | **OSPF area 0** on transit; **BGP AS65102** peers r1 loopback `10.99.1.1` (`update-source lo`, `ebgp-multihop 2`); advertises `172.31.20.0/24` into BGP |
| `onprem-host` | Server / probe target | — | `172.31.20.10/24`, default via `172.31.20.1` | serves HTTP :80 |

### Control plane

- **OSPF area 0** is the on-prem **IGP underlay**. It runs over the transit
  `172.31.12.0/30` (`point-to-point`) and carries the router **loopbacks**
  (`10.99.1.1/32`, `10.99.2.2/32`) — advertised **only via OSPF**, not BGP.
- **eBGP** between `onprem-r1` (AS65101) and `onprem-r2` (AS65102) peers
  **loopback-to-loopback** (`update-source lo`, `ebgp-multihop 2`, fast timers
  `3 9`). Because each router can only reach the peer loopback via the
  OSPF-learned route, **BGP is reliant on the OSPF underlay**.
- The **on-prem LAN** `172.31.20.0/24` is reachable because r2 originates it into
  BGP; `onprem-r1` originates the return `172.31.11.0/30`. On r1 the LAN route is
  **recursive over `10.99.2.2`** (the OSPF-learned peer loopback).
- **Cascade (the key design property):** breaking the r1↔r2 **OSPF adjacency**
  withdraws the peer loopback → the loopback-peered **BGP session drops** → the
  **LAN `172.31.20.0/24` is withdrawn** in both directions → the
  `netsre-clab-connection-monitor` probe fails. So an **IGP fault now cascades all
  the way to the data path** and is detectable, mirroring a real WAN "IGP underlay
  + BGP over loopbacks" design. Fast OSPF (`dead-interval 8`) + BGP (`timers 3 9`)
  make the cascade converge in ~15s.
- Naturally, a direct **BGP session/policy fault or a transit-link fault** also
  withdraws the LAN and fails the CM.

### Azure data-path integration (T3)

The Azure lab-host VM (`10.100.1.5`) has a host veth `clabr1host` =
`172.31.11.1/30` and a route `172.31.20.0/24 via 172.31.11.2` (→ r1). It runs the
**Network Watcher agent**, and Connection Monitor
`netsre-clab-connection-monitor` probes `172.31.20.10` (ICMP + HTTP:80). The probe
path is `host → r1 → eBGP → r2 → onprem-host`, so an r1↔r2 control-plane fault
fails the probe in **both** directions and raises `netsre-clab-cm-checks-failed`.

---

## How to inspect the fabric

> **The clab Connection Monitor's source VM `netsre-onprem-clab` (10.100.1.5) is
> also the fabric host** — the routers are Docker containers on it. For a
> `netsre-clab-*` alert, inspect the fabric **on that same VM** with `docker exec
> … vtysh`; a missing host-level `vtysh` is expected and does **not** mean "no
> router here". Do **not** confuse it with `netsre-onprem-frr` (10.100.1.201, the
> Stage-1 router VM, often deallocated) — that VM is **not** in the clab probe
> path, so a deallocated `netsre-onprem-frr` is a red herring for clab CM alerts.

```bash
# On the netsre-onprem-clab VM (10.100.1.5):
sudo containerlab inspect -t /opt/onprem/onprem.clab.yml
docker exec -it clab-onprem-onprem-r1 vtysh -c 'show ip bgp summary'
docker exec -it clab-onprem-onprem-r2 vtysh -c 'show ip route'
```

> Run multi-command `vtysh`/`docker exec` via `az vm run-command` by
> **base64-encoding** the bash script (nested quotes are otherwise mangled) and
> running `echo <b64> | base64 -d | bash`. Use `vtysh -c 'configure terminal'`,
> never `conf t`.

---

## Related documents

- `knowledge/onprem-telemetry-and-observability.md` — where on-prem signals land
  in Azure Monitor and how to query them.
- `knowledge/onprem-bgp-fault-runbook.md` — triaging a broken r1↔r2 BGP session.
- `knowledge/onprem-ospf-fault-runbook.md` — triaging an OSPF adjacency/misconfig.
- `docs/onprem-telemetry-pipelines-how-it-works.md` — full pipeline internals.
- `infra/containerlab/README.md` — fabric build + T3 wiring details.
