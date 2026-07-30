# On-prem Containerlab fabric (Part A2 — high-fidelity simulation)

A small **containerized on-prem network** that runs inside a single Azure "lab
host" VM. This is the high-fidelity simulation option (**Part A2**) from
[`docs/onprem-network-simulation-and-telemetry.md`](../../docs/onprem-network-simulation-and-telemetry.md):
instead of a single soft-router VM, it runs real network-OS containers wired
together by [Containerlab](https://containerlab.dev/), giving realistic vendor
CLIs, syslog formats and (with SR Linux) gNMI/SNMP telemetry.

> **Deep dive:** [`docs/containerlab-onprem-how-it-works.md`](../../docs/containerlab-onprem-how-it-works.md)
> explains exactly how Containerlab wires the fabric (management bridge, veth pairs,
> namespaces) and how the eBGP control plane behaves — with **real captured command
> output** from the running lab, plus a BGP fault demo and the LF-line-endings gotcha.

## Topology

```
          eBGP (65101 <-> 65102)
  onprem-r1 ───────────────────── onprem-r2 ───────── onprem-host
  (WAN edge)   172.31.12.0/30     (core)  172.31.20.0/24  (server, HTTP :80)
  lo 10.99.1.1                    lo 10.99.2.2            172.31.20.10
```

- **onprem-r1 / onprem-r2** — FRRouting routers running an eBGP session. `r2`
  owns the on-prem LAN (`172.31.20.0/24`) and advertises it; `r1` is the WAN edge.
  They **also run OSPF area 0** over the transit link as the on-prem IGP, carrying
  the router loopbacks (`10.99.1.1/32`, `10.99.2.2/32`) — advertised *only* via
  OSPF, not BGP.
- **onprem-host** — a Linux server on the LAN, default route via `r2`, serving
  HTTP on port 80 (a probe target).

Breaking the `r1<->r2` BGP session or the transit link withdraws the LAN route
from `r1`, so `onprem-host` becomes unreachable from the edge — a realistic,
observable **control-plane** fault. An **OSPF** misconfig (area/network-type/MTU
mismatch) instead breaks internal loopback reachability *without* touching the
BGP-carried data path — see `knowledge/onprem-ospf-fault-runbook.md`.

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

### OSPF misconfig (IGP fault, does NOT affect the BGP data path)

```bash
# Area mismatch on the transit — adjacency drops, peer loopback withdrawn
docker exec -it clab-onprem-onprem-r1 vtysh -c 'configure terminal' \
  -c 'router ospf' -c 'no network 172.31.12.0/30 area 0' \
  -c 'network 172.31.12.0/30 area 1'

docker exec -it clab-onprem-onprem-r1 vtysh -c 'show ip ospf neighbor'   # empty
docker exec -it clab-onprem-onprem-r1 ping -c2 -I 10.99.1.1 10.99.2.2    # fails
# BGP + 172.31.20.0/24 remain UP throughout. Revert: swap area 1 -> area 0.
```

> Prefer `vtysh -c 'configure terminal'` (not `conf t`) and, over
> `az vm run-command`, **base64-encode** the script — nested quotes are otherwise
> corrupted.

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

## Relationship to the Azure data path (T3) — implemented

This fabric is now wired into the Azure Connection Monitor data path (option
**T3** in the design doc) so that **control-plane faults inside the containerlab
fabric are observable from Azure**.

### How the traversal works

A host-facing veth (`clabr1host`) connects the host VM to `onprem-r1:eth2` on the
transit subnet `172.31.11.0/30`:

- Host side `clabr1host` = `172.31.11.1/30`, with a route
  `172.31.20.0/24 via 172.31.11.2` pushed into the host VM.
- `onprem-r1:eth2` = `172.31.11.2/30`; r1 advertises `172.31.11.0/30` into BGP so
  the **return path is also BGP-dependent**.

The host VM runs the **Network Watcher agent extension** (added in
`onprem-containerlab.bicep`), making it a valid Connection Monitor **source**. The
CM `netsre-clab-connection-monitor` (`onprem-clab-connection-monitor.bicep`)
probes from the host VM to the in-fabric server `172.31.20.10` (ICMP + HTTP:80),
which routes host → r1 → **eBGP** → r2 → server.

Because both the forward path (host route → r1 → r2) and the return path
(r2 → r1 → BGP-learned `172.31.11.0/30`) depend on the `onprem-r1 ↔ onprem-r2`
eBGP session, **breaking that session (or the r1/r2 link) fails the CM probe** and
raises `netsre-clab-cm-checks-failed` / `netsre-clab-cm-test-result-fail`.
Verified live: normal probe `ttl=62` (2 hops) + `HTTP:200`; BGP down →
`% Network not in table` + 100% loss; restore → passes.

### Caveat — cloud-init script is baked at first boot

`/usr/local/bin/onprem-clab-up.sh` is written by cloud-init `write_files` **once**
at VM creation. Re-running it pulls fresh topology files from git (so
`onprem.clab.yml` + `frr.conf` updates apply on redeploy), but it does **not**
rewrite the script itself — the host-veth wiring (veth IP + route) only takes
effect on a **fresh** clab VM deploy. On an existing VM apply it manually via
run-command (base64-encode the bash to avoid quoting corruption; see SKILL.md).
