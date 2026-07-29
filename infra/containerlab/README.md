# On-prem Containerlab fabric (Part A2 — high-fidelity simulation)

A small **containerized on-prem network** that runs inside a single Azure "lab
host" VM. This is the high-fidelity simulation option (**Part A2**) from
[`docs/onprem-network-simulation-and-telemetry.md`](../../docs/onprem-network-simulation-and-telemetry.md):
instead of a single soft-router VM, it runs real network-OS containers wired
together by [Containerlab](https://containerlab.dev/), giving realistic vendor
CLIs, syslog formats and (with SR Linux) gNMI/SNMP telemetry.

## Topology

```
          eBGP (65101 <-> 65102)
  onprem-r1 ───────────────────── onprem-r2 ───────── onprem-host
  (WAN edge)   172.31.12.0/30     (core)  172.31.20.0/24  (server, HTTP :80)
  lo 10.99.1.1                    lo 10.99.2.2            172.31.20.10
```

- **onprem-r1 / onprem-r2** — FRRouting routers running an eBGP session. `r2`
  owns the on-prem LAN (`172.31.20.0/24`) and advertises it; `r1` is the WAN edge.
- **onprem-host** — a Linux server on the LAN, default route via `r2`, serving
  HTTP on port 80 (a probe target).

Breaking the `r1<->r2` BGP session or the transit link withdraws the LAN route
from `r1`, so `onprem-host` becomes unreachable from the edge — a realistic,
observable **control-plane** fault.

## Prerequisites

- A Linux host with Docker and Containerlab installed. The Azure lab host VM
  (`infra/modules/onprem-containerlab.bicep`) provisions both automatically via
  cloud-init and deploys this topology on first boot.
- To run it manually on any Docker host:

```bash
bash -c "$(curl -sL https://get.containerlab.dev)"   # install containerlab
cd infra/containerlab
sudo containerlab deploy -t onprem.clab.yml
```

## Operating the fabric

```bash
sudo containerlab inspect -t onprem.clab.yml          # node list + mgmt IPs
docker exec -it clab-onprem-onprem-r1 vtysh           # router CLI (FRR)
docker exec -it clab-onprem-onprem-r1 vtysh -c 'show ip bgp summary'
docker exec -it clab-onprem-onprem-host curl -s 172.31.20.10   # HTTP target
sudo containerlab destroy -t onprem.clab.yml          # tear down
```

## Fault injection examples (control-plane)

```bash
# Drop the eBGP session from the edge — LAN route disappears on r1
docker exec -it clab-onprem-onprem-r1 vtysh -c 'conf t' \
  -c 'router bgp 65101' -c 'neighbor 172.31.12.2 shutdown'

# Break the transit link entirely
docker exec -it clab-onprem-onprem-r1 ip link set dev eth1 down

# Verify the impact
docker exec -it clab-onprem-onprem-r1 vtysh -c 'show ip route 172.31.20.0/24'
```

## Higher fidelity: Nokia SR Linux

The default images (FRR + `network-multitool`) are free and need no vendor
account. For real vendor telemetry (gNMI streaming, native SNMP MIBs, vendor
syslog), swap the router nodes to **Nokia SR Linux**, which is publicly pullable:

```yaml
    onprem-r1:
      kind: nokia_srlinux
      image: ghcr.io/nokia/srlinux:latest
      # provide an SR Linux startup-config via: startup-config: configs/r1-srl.cfg
```

SR Linux exposes gNMI on 57400 and JSON-RPC on 443; point an OpenTelemetry
Collector / Telegraf gNMI input at it and export to Azure Monitor (Part B).

## Relationship to the Azure data path (T3)

By default this fabric is **self-contained inside the host VM** — a faithful
on-prem simulation for telemetry/audit/CLI demos. To make an in-fabric host a
Connection Monitor **target** reachable from Azure spokes (option **T3** in the
design doc, requires **D3c**), the fabric's LAN must be bridged to the host VM's
Azure NIC (macvlan/host networking) and routed across the VPN underlay. That
integration is intentionally out of scope for this first A2 drop; the FRR-on-VM
tiers (Stage 1, options T1/T2) remain the recommended in-path detection design.
