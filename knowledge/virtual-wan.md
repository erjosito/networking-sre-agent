# Azure Virtual WAN — SRE Knowledge Base

## Overview

Azure Virtual WAN (VWAN) is a Microsoft-managed networking service that provides optimized and automated
branch-to-branch, branch-to-Azure, and Azure-to-Azure connectivity through a global transit network
architecture. It consolidates networking, security, and routing functions into a single operational
interface.

### What Virtual WAN Provides

- **Global transit architecture** — Any-to-any connectivity between branches, VNets, and users
- **Managed hub infrastructure** — Microsoft-managed virtual hubs deployed in Azure regions
- **Integrated SD-WAN** — Partner CPE auto-provisioning and connectivity
- **Built-in security** — Azure Firewall and third-party NVA integration in the hub
- **Unified routing** — Centralized route management across all connected networks
- **Encryption** — VPN over ExpressRoute, hub-to-hub encryption

### When to Use Virtual WAN vs Traditional Hub-Spoke

| Criteria | Virtual WAN | Traditional Hub-Spoke |
|---|---|---|
| Number of branches/sites | > 20–30 sites | < 20 sites |
| Hub routing management | Fully managed by Microsoft | User-managed UDRs on hub VNet |
| Inter-hub (cross-region) transit | Automatic via Microsoft backbone | Manual peering + UDRs |
| SD-WAN integration | Native partner integration | Manual configuration |
| Azure Firewall in hub | Secured Virtual Hub (managed) | Self-deployed in hub VNet |
| Granular UDR control on hub | Limited (no UDRs on hub VNet) | Full control |
| NVA in the hub itself | Supported (select partners) | Full flexibility |
| Cost sensitivity | Higher baseline cost | Lower baseline, higher ops cost |

**Key decision factors:**

- Choose VWAN when you need automated any-to-any connectivity at scale with many branches
- Choose traditional hub-spoke when you need full control over hub routing (UDRs on hub subnet),
  custom NVA topologies, or have a small number of connections
- VWAN hubs do not support user-defined routes on the hub VNet itself — routing is managed
  via VWAN route tables

---

## Architecture

### Virtual WAN Resource Hierarchy

```
Virtual WAN (resource)
 └── Virtual Hub (per region)
      ├── VPN Gateway (S2S)
      ├── ExpressRoute Gateway
      ├── P2S VPN Gateway
      ├── Azure Firewall (Secured Hub)
      ├── NVA (Network Virtual Appliance)
      ├── VNet Connections
      └── Route Tables
```

### Virtual WAN Types

- **Basic** — S2S VPN only. No ExpressRoute, P2S, inter-hub, or VNet-to-VNet transit.
- **Standard** — Full feature set: S2S, P2S, ExpressRoute, inter-hub transit, VNet-to-VNet,
  Azure Firewall, routing intent, NVA-in-hub.

> **SRE Note:** You cannot downgrade from Standard to Basic. Always deploy Standard for
> production workloads.

### Virtual Hub

A Virtual Hub is a Microsoft-managed VNet in a specific Azure region. It has its own address
space (e.g., 10.100.0.0/23) and contains gateway infrastructure. You do not have direct access
to the hub VNet — you cannot deploy VMs, add NSGs, or create UDRs on hub subnets.

**Hub address space requirements:**

- Minimum /24 (256 addresses) — but Microsoft recommends /23
- Must not overlap with any connected VNet or on-premises range
- Cannot be modified after creation without redeployment

### Secured Virtual Hub

A Secured Virtual Hub is a Virtual Hub with Azure Firewall (or third-party security provider)
deployed and managed through Azure Firewall Manager. When Routing Intent is configured, the
hub automatically injects routes so that all traffic (private and/or internet) flows through
the firewall.

```
                    ┌───────────────────────────────┐
                    │       Secured Virtual Hub      │
                    │                                │
  S2S VPN ──────── │  ┌──────────┐  ┌────────────┐  │ ──── VNet Connections
  P2S VPN ──────── │  │ Gateways │──│  Azure FW   │  │ ──── Spoke VNets
  ExpressRoute ─── │  └──────────┘  └────────────┘  │
                    │       Route Tables              │
                    └───────────────────────────────┘
                              │
                         Inter-hub link
                              │
                    ┌───────────────────────────────┐
                    │     Hub (another region)       │
                    └───────────────────────────────┘
```

### Hub-to-Hub Connectivity

In Standard VWAN, hubs in different regions automatically form a full mesh via the Microsoft
global backbone. Traffic between hubs traverses Microsoft's private network — not the public
internet.

- Inter-hub bandwidth follows the hub SKU and region pair pricing
- Inter-hub latency is determined by physical region distance
- Routes are automatically exchanged between hubs via the VWAN routing service

---

## Routing

### Route Tables

Virtual WAN uses route tables to control traffic flow. Every hub has a **Default route table**
(`defaultRouteTable`) and supports custom route tables.

Key concepts:

- **Association** — Each connection (VNet, VPN, ExpressRoute) is associated with exactly one
  route table. This determines which route table is used for traffic originating from that
  connection. Think of it as: "traffic FROM this connection looks up routes in this table."
- **Propagation** — Each connection propagates its routes to one or more route tables.
  Think of it as: "this connection's routes are advertised TO these tables."
- **Labels** — A label is an alias for a group of route tables. Propagating to a label
  propagates to all route tables that carry that label. The built-in label `default`
  includes the `defaultRouteTable`.

**Default behavior (all connections associated + propagated to defaultRouteTable):**

- All VNets can reach all VPN/ER branches → any-to-any
- All VNets can reach each other → full mesh

### Static Routes

Static routes can be added to route tables to override or supplement learned routes:

```bash
# Add a static route to send 10.50.0.0/16 via a VNet connection (e.g., NVA in spoke)
az network vhub route-table route add \
  --resource-group myRG \
  --vhub-name myHub \
  --route-table-name defaultRouteTable \
  --route-name toSharedServices \
  --destination-type CIDR \
  --destinations 10.50.0.0/16 \
  --next-hop-type ResourceId \
  --next-hop /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualHubs/{hub}/hubVirtualNetworkConnections/{connName}
```

### Routing Intent and Routing Policies

Routing Intent is a mechanism to configure the hub so that all private traffic and/or internet
traffic is sent through a security solution (Azure Firewall or NVA) deployed in the hub.

**Two policies:**

- **Internet Traffic Policy** — Routes 0.0.0.0/0 through the security solution
- **Private Traffic Policy** — Routes all RFC 1918 prefixes (10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16) through the security solution, plus any additional private prefixes

**When Routing Intent is enabled:**

- The hub automatically programs a 0.0.0.0/0 and/or RFC 1918 routes on all connections
- You cannot manually configure association/propagation on connections — the hub manages it
- Static routes on the defaultRouteTable are overridden by Routing Intent
- All inter-hub traffic also goes through the local hub's firewall

```bash
# Configure routing intent with both private and internet policies
az network vhub routing-intent create \
  --resource-group myRG \
  --vhub-name myHub \
  --name myRoutingIntent \
  --routing-policies "[
    {name: InternetTraffic, destinations: [Internet], nextHop: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/azureFirewalls/{fwName}},
    {name: PrivateTraffic, destinations: [PrivateTraffic], nextHop: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/azureFirewalls/{fwName}}
  ]"
```

> **SRE Warning:** Enabling Routing Intent is a significant change. It will redirect ALL
> traffic through the firewall. Ensure firewall rules are in place BEFORE enabling, or
> you will break connectivity.

### Effective Routes

To troubleshoot routing issues, inspect effective routes on a connection or route table:

```bash
# Get effective routes for a VNet connection
az network vhub get-effective-routes \
  --resource-group myRG \
  --name myHub \
  --resource-type VirtualNetworkConnection \
  --resource-id /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualHubs/{hub}/hubVirtualNetworkConnections/{conn}

# Get effective routes for the default route table
az network vhub get-effective-routes \
  --resource-group myRG \
  --name myHub \
  --resource-type RouteTable \
  --resource-id /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualHubs/{hub}/hubRouteTables/defaultRouteTable
```

### BGP Peering with NVAs

Virtual WAN hubs support BGP peering with NVAs deployed in spoke VNets or in the hub:

```bash
# Create a BGP connection to an NVA in a spoke
az network vhub bgpconnection create \
  --resource-group myRG \
  --vhub-name myHub \
  --name nva-bgp-conn \
  --peer-ip 10.10.1.4 \
  --peer-asn 65010 \
  --vhub-conn /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualHubs/{hub}/hubVirtualNetworkConnections/{connName}
```

**BGP peering requirements:**

- NVA must be in a spoke VNet connected to the hub
- The VNet connection must have "Propagate Static Route" enabled
- NVA ASN must not conflict with the hub's ASN (65520)
- The VWAN hub peers from its virtual router IPs (visible in hub properties)

---

## Connectivity

### Site-to-Site VPN (S2S)

S2S VPN connects on-premises branches to the Virtual Hub via IPsec/IKE tunnels.

**Key parameters:**

- **Scale units** — Determines gateway throughput (1 unit = 500 Mbps, max 20 units = 20 Gbps aggregate)
- **Active-Active** — Both gateway instances active by default
- **Custom IPsec policies** — Per-link or per-site IKE/IPsec configuration
- **BGP** — Supported for dynamic route exchange with on-prem

```bash
# Create a VPN site
az network vpn-site create \
  --resource-group myRG \
  --name branch-office-1 \
  --virtual-wan myVwan \
  --ip-address 203.0.113.1 \
  --address-prefixes 10.200.0.0/16 \
  --device-vendor Cisco \
  --device-model ISR4451

# Create a VPN connection linking site to hub gateway
az network vpn-gateway connection create \
  --resource-group myRG \
  --gateway-name myHub-vpngw \
  --name conn-branch-1 \
  --remote-vpn-site /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/vpnSites/branch-office-1 \
  --enable-bgp true \
  --shared-key "YourPreSharedKey"
```

### Point-to-Site VPN (P2S)

P2S VPN allows individual clients to connect to the VWAN hub.

**Supported protocols:** OpenVPN, IKEv2, SSTP (not recommended for VWAN)

```bash
# Create a P2S VPN gateway
az network p2s-vpn-gateway create \
  --resource-group myRG \
  --name myHub-p2sgw \
  --vhub myHub \
  --scale-unit 1 \
  --vpn-server-config myP2SConfig \
  --address-space 172.16.0.0/24
```

**DNS considerations for P2S:**

- Custom DNS servers must be configured on the P2S gateway or VWAN hub settings
- Azure Private DNS Zones require a DNS forwarder in a spoke VNet
- P2S clients may fail to resolve private endpoints if DNS is misconfigured

### ExpressRoute

ExpressRoute provides private, dedicated connectivity from on-premises to Azure via an
ExpressRoute circuit.

```bash
# Create an ExpressRoute gateway in the hub
az network express-route gateway create \
  --resource-group myRG \
  --name myHub-ergw \
  --virtual-hub myHub \
  --min-val 1 --max-val 2

# Connect an ExpressRoute circuit
az network express-route gateway connection create \
  --resource-group myRG \
  --gateway-name myHub-ergw \
  --name conn-er-circuit1 \
  --peering /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/expressRouteCircuits/{circuit}/peerings/AzurePrivatePeering
```

**ExpressRoute + VWAN key behaviors:**

- ExpressRoute-connected VNets automatically learn routes from branches and other VNets
- ExpressRoute-to-ExpressRoute transit (Global Reach) requires explicit enablement
- VPN-to-ExpressRoute transit through the hub is supported (encrypted transit)

### VNet Connections

VNet connections attach spoke VNets to the VWAN hub:

```bash
az network vhub connection create \
  --resource-group myRG \
  --vhub-name myHub \
  --name conn-spoke1 \
  --remote-vnet /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/spoke1-vnet \
  --internet-security true
```

**Key settings:**

- `--internet-security true` — Propagates the 0.0.0.0/0 route to the spoke (required for
  internet routing through hub firewall)
- Association / propagation to route tables (unless Routing Intent overrides)
- Static routes can be defined on the connection itself for summarization

### Inter-Hub Routing

When multiple hubs exist in a VWAN:

- Routes are automatically propagated between hubs
- Traffic follows the Microsoft backbone (not internet)
- With Routing Intent enabled, inter-hub traffic goes through EACH hub's firewall
  (local firewall at source hub → backbone → remote firewall at destination hub)

---

## Security

### Secured Virtual Hub with Azure Firewall

Azure Firewall Manager integrates Azure Firewall into the VWAN hub:

- Deploy Azure Firewall (Standard or Premium) directly inside the hub
- Firewall policies are authored in Azure Firewall Manager and applied to the hub
- Routing Intent automates traffic steering — no manual UDR management

**Firewall policy association:**

```bash
# Associate a firewall policy with the secured hub
az network firewall update \
  --resource-group myRG \
  --name myHub-azfw \
  --firewall-policy /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/firewallPolicies/myPolicy
```

### Routing Intent and Security Policies

When configuring Routing Intent for security:

1. **Internet policy only** — Hub advertises 0.0.0.0/0 to all connections, forcing
   internet-bound traffic through the firewall. Private traffic still routes directly.
2. **Private policy only** — Hub advertises RFC 1918 routes through the firewall.
   Internet traffic uses the default path (direct from spoke).
3. **Both policies** — All traffic (private + internet) goes through the firewall.

> **SRE Note:** With private traffic policy enabled, spoke-to-spoke traffic within
> the same hub also traverses the firewall. This is different from traditional hub-spoke
> where peered VNets can communicate directly.

### Third-Party NVAs in Virtual WAN

VWAN supports deploying partner NVAs (e.g., Barracuda, Check Point, Fortinet, Cisco)
directly in the hub via Managed Applications:

- NVA is deployed as a managed resource inside the hub
- Routes are programmed to steer traffic through the NVA
- NVA can be used as the next hop in Routing Intent (instead of Azure Firewall)
- Supports both security (NGFW) and SD-WAN functions

**NVA in spoke VNet (alternative pattern):**

- NVA is deployed in a regular spoke VNet
- Static routes on the route table point traffic to the spoke VNet connection
- BGP peering between NVA and hub enables dynamic route advertisement
- Requires careful UDR configuration on spoke subnets to prevent routing loops

---

## Common Failure Scenarios

### 1. VPN Branch Connectivity Failures

**Symptoms:** On-premises site cannot reach Azure resources. IPsec tunnel shows disconnected.

**Common causes:**

- **IKE/IPsec mismatch** — Phase 1 or Phase 2 parameters don't match between on-prem
  device and VWAN VPN gateway
- **Pre-shared key mismatch** — Key differs between VPN site config and on-prem device
- **Public IP unreachable** — ISP or on-prem firewall blocking UDP 500/4500
- **BGP not established** — Wrong ASN, incorrect BGP peer IP, or missing eBGP multihop
- **NAT-T issues** — NAT device between on-prem and Azure interfering with IPsec

**Troubleshooting steps:**

```bash
# Check VPN connection status
az network vpn-gateway connection show \
  --resource-group myRG \
  --gateway-name myHub-vpngw \
  --name conn-branch-1 \
  --query '{status:connectionStatus, inBytes:ingressBytesTransferred, outBytes:egressBytesTransferred}'

# Download VPN config for the site (verify parameters match on-prem)
az network vpn-site download \
  --resource-group myRG \
  --virtual-wan myVwan \
  --vpn-sites branch-office-1 \
  --output-blob-sas-url "<sas-url>"
```

### 2. Routing Asymmetry Between Hubs

**Symptoms:** Traffic from Hub A to a spoke behind Hub B takes an unexpected path,
or return traffic takes a different path than forward traffic.

**Common causes:**

- Route preference differences — One hub learns a more specific route via a different path
- ExpressRoute vs VPN preference — ExpressRoute routes (AS path length) preferred over VPN
- Routing Intent on one hub but not the other — Causes asymmetric firewall inspection
- Static routes on one hub overriding dynamic routes

**Resolution:**

- Ensure Routing Intent is configured consistently across ALL hubs
- Verify route table propagation is symmetric
- Check effective routes on both hubs to compare learned routes:

```bash
# Compare effective routes on both hubs
az network vhub get-effective-routes --resource-group myRG --name hub-eastus ...
az network vhub get-effective-routes --resource-group myRG --name hub-westeurope ...
```

### 3. Misconfigured Routing Intent Blocking Traffic

**Symptoms:** After enabling Routing Intent, all or some traffic stops flowing.

**Common causes:**

- **Firewall rules missing** — Routing Intent steers traffic to firewall, but no Allow
  rules exist for the required flows
- **DNS broken** — Internet policy forces DNS traffic through firewall; if firewall
  doesn't proxy DNS or allow UDP 53, name resolution fails
- **Private endpoint resolution failure** — Traffic to private endpoints now goes through
  firewall, which may not have FQDN rules or network rules for PaaS IPs
- **Asymmetric routing** — Routing Intent on some hubs but not all

**Troubleshooting:**

```bash
# Check Azure Firewall logs for denied traffic
az monitor log-analytics query \
  --workspace <workspace-id> \
  --analytics-query "AZFWNetworkRule | where Action == 'Deny' | top 50 by TimeGenerated"

# Or for application rules
az monitor log-analytics query \
  --workspace <workspace-id> \
  --analytics-query "AZFWApplicationRule | where Action == 'Deny' | top 50 by TimeGenerated"
```

### 4. Missing Route Table Associations/Propagations

**Symptoms:** A spoke VNet can reach some resources but not others. Branches cannot reach
certain spokes.

**Common causes:**

- VNet connection associated with a non-default route table but that table lacks routes
- VNet connection not propagating to the expected route table
- Label mismatch — VNet propagates to label `default` but the connection receiving traffic
  uses a custom route table not in the `default` label
- New VNet connection created with default settings overriding intended isolation

**Troubleshooting:**

```bash
# Check association and propagation for a connection
az network vhub connection show \
  --resource-group myRG \
  --vhub-name myHub \
  --name conn-spoke1 \
  --query '{association:routingConfiguration.associatedRouteTable.id, propagation:routingConfiguration.propagatedRouteTables}'

# List all route tables and their routes
az network vhub route-table list \
  --resource-group myRG \
  --vhub-name myHub \
  --query '[].{name:name, routes:routes}'
```

### 5. NVA in Spoke Not Receiving Traffic

**Symptoms:** An NVA deployed in a spoke VNet is supposed to inspect traffic, but traffic
bypasses it.

**Common causes:**

- **Missing static route** — No static route on the VWAN route table pointing to the
  spoke connection as next hop
- **Missing UDR on spoke subnet** — Spoke subnets need a UDR pointing 0.0.0.0/0 to
  the NVA's private IP for return traffic
- **IP forwarding disabled** — NVA NIC must have IP forwarding enabled
- **Propagate gateway routes = No** — If the spoke has "Propagate gateway routes"
  disabled on its route table, it won't learn VWAN routes
- **BGP not configured** — If using BGP peering, verify the BGP session is established

**Resolution checklist:**

1. Static route on VWAN route table → spoke VNet connection as next hop
2. UDR on spoke subnets → NVA IP for return traffic
3. IP forwarding enabled on NVA NIC(s)
4. NSG on NVA subnet allows the forwarded traffic
5. NVA internal routing/firewall rules permit the traffic

### 6. ExpressRoute Hairpin Routing Issues

**Symptoms:** Traffic from one ExpressRoute circuit needs to reach another ER-connected
site, but communication fails or takes an unintended path.

**Common causes:**

- **ER-to-ER transit not enabled** — By default, VWAN does NOT enable ExpressRoute-to-
  ExpressRoute transit. You must explicitly enable Global Reach on the circuits or use
  routing through the hub.
- **Route length / AS path** — ER routes with longer AS paths may be deprioritized
- **Bandwidth bottleneck** — Transit traffic through the hub consumes hub gateway capacity

**Options for ER-to-ER connectivity:**

1. **ExpressRoute Global Reach** — Direct circuit-to-circuit peering (bypasses Azure hub)
2. **Transit through VWAN hub** — Requires S2S VPN or routing through hub; ER-to-ER via
   hub requires specific configuration
3. **Secured hub with Routing Intent** — Private traffic policy can enable ER-to-ER
   transit through the firewall

### 7. P2S VPN DNS Resolution Failures

**Symptoms:** P2S VPN clients connect successfully but cannot resolve private DNS names
(e.g., privatelink.blob.core.windows.net).

**Common causes:**

- **No custom DNS configured** — P2S clients default to Azure-provided DNS which doesn't
  resolve Private DNS Zones linked to spoke VNets
- **DNS forwarder unreachable** — Custom DNS server configured but not reachable from
  P2S address pool
- **Split DNS not configured** — Client resolves public IP for services instead of
  private endpoint IP
- **Private DNS Zone not linked** — Zone not linked to the DNS forwarder's VNet

**Resolution:**

1. Deploy a DNS forwarder (Azure DNS Private Resolver or VM-based) in a spoke VNet
2. Link all Private DNS Zones to the forwarder's VNet
3. Configure P2S gateway custom DNS to point to the forwarder IP
4. Verify P2S address pool can route to the DNS forwarder

```bash
# Set custom DNS on the P2S VPN gateway
az network p2s-vpn-gateway update \
  --resource-group myRG \
  --name myHub-p2sgw \
  --custom-dns-servers 10.10.5.4
```

---

## Troubleshooting

### Effective Routes Analysis

Effective routes are the single most important troubleshooting tool for VWAN routing:

```bash
# Effective routes on a VNet connection
az network vhub get-effective-routes \
  --resource-group myRG \
  --name myHub \
  --resource-type VirtualNetworkConnection \
  --resource-id <connection-resource-id>

# Effective routes on a route table
az network vhub get-effective-routes \
  --resource-group myRG \
  --name myHub \
  --resource-type RouteTable \
  --resource-id <route-table-resource-id>

# Effective routes on VPN gateway
az network vhub get-effective-routes \
  --resource-group myRG \
  --name myHub \
  --resource-type VpnGateway \
  --resource-id <vpn-gateway-resource-id>
```

**What to look for:**

- Missing expected prefixes (propagation issue)
- Wrong next hop (association or static route issue)
- Duplicate prefixes with different next hops (route conflict)
- 0.0.0.0/0 present or absent (Routing Intent / internet security)

### BGP Dashboard

The VWAN hub BGP dashboard (Portal: Virtual Hub → BGP Peers) shows:

- All BGP peers and their status (Connected / Not Connected)
- Learned routes per peer
- Advertised routes per peer
- Hub's virtual router ASN and IPs

```bash
# List BGP peer status
az network vhub bgpconnection list \
  --resource-group myRG \
  --vhub-name myHub \
  --query '[].{name:name, peerIp:peerIp, peerAsn:peerAsn, connectionState:connectionState}'
```

### Network Watcher Tools

- **Connection Troubleshoot** — Test TCP/ICMP connectivity from a VM to a destination
  through the VWAN path
- **IP Flow Verify** — Check if NSGs would allow/deny specific traffic
- **Next Hop** — Determine the next hop for a packet leaving a spoke VM
  (should show Virtual Network Gateway or VNet peering for VWAN-connected spokes)
- **Packet Capture** — Capture packets on spoke VMs to diagnose data-plane issues
- **VPN Troubleshoot** — Run diagnostics on the VPN gateway

```bash
# Test connectivity from a spoke VM through VWAN
az network watcher test-connectivity \
  --resource-group myRG \
  --source-resource vmInSpoke1 \
  --dest-address 10.200.1.10 \
  --dest-port 443

# VPN gateway diagnostics
az network vpn-gateway reset \
  --resource-group myRG \
  --name myHub-vpngw
```

### Azure Monitor Metrics and Logs

**Key metrics to monitor:**

| Metric | Resource | What it tells you |
|---|---|---|
| Tunnel Ingress/Egress Bytes | VPN Gateway | Traffic volume per tunnel |
| Tunnel Ingress/Egress Packets | VPN Gateway | Packet throughput |
| BGP Peer Status | VPN Gateway | 1 = up, 0 = down |
| BGP Routes Advertised/Learned | VPN Gateway | Route exchange health |
| Hub Routed Data | Virtual Hub | Data processed by hub router |
| ExpressRoute Bits In/Out | ER Gateway | Circuit utilization |
| Firewall Throughput | Azure Firewall | FW processing capacity |
| SNAT Port Utilization | Azure Firewall | Outbound connection capacity |

**Diagnostic settings — enable these:**

```bash
# Enable diagnostic logs on VPN gateway
az monitor diagnostic-settings create \
  --resource /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/vpnGateways/{gwName} \
  --name vpn-diag \
  --workspace <log-analytics-workspace-id> \
  --logs '[{"category":"RouteDiagnosticLog","enabled":true},{"category":"IKEDiagnosticLog","enabled":true},{"category":"TunnelDiagnosticLog","enabled":true}]'
```

**Key Log Analytics (KQL) queries:**

```kql
// VPN tunnel status changes
AzureDiagnostics
| where Category == "TunnelDiagnosticLog"
| project TimeGenerated, remoteIP_s, status_s, stateChangeReason_s
| order by TimeGenerated desc

// IKE negotiation failures
AzureDiagnostics
| where Category == "IKEDiagnosticLog"
| where Message contains "failed" or Message contains "error"
| project TimeGenerated, remoteIP_s, Message
| order by TimeGenerated desc

// Azure Firewall denied flows (Structured Logs)
AZFWNetworkRule
| where Action == "Deny"
| summarize count() by SourceIp, DestinationIp, DestinationPort, Protocol
| order by count_ desc

// Route changes
AzureDiagnostics
| where Category == "RouteDiagnosticLog"
| project TimeGenerated, routePrefix_s, nextHopType_s, resultType_s
| order by TimeGenerated desc
```

---

## Best Practices

### Hub Placement

- **Deploy hubs in regions where you have workloads** — Minimize latency between spokes
  and their hub
- **Consider branch proximity** — Place hubs near the geographic regions where branches
  are located for optimal VPN/ER latency
- **Use paired regions** — For disaster recovery, deploy hubs in Azure paired regions
- **Avoid too many hubs** — Each hub incurs cost; consolidate where latency permits

### Hub Address Space Planning

- Allocate a /23 for each hub (Microsoft recommendation)
- Use a dedicated supernet for all VWAN hub addressing (e.g., 10.100.0.0/16)
- Plan for future hubs in the address scheme
- Document hub addressing centrally — overlaps cause deployment failures

### Connectivity Patterns

- **Always enable BGP on S2S VPN connections** — Dynamic routing adapts to changes
  automatically; static routing requires manual updates
- **Use Active-Active VPN** — Both gateway instances handle traffic for better resiliency
- **Configure connection draining** before maintenance — Gracefully shift traffic before
  resets or updates
- **Monitor tunnel health proactively** — Set alerts on tunnel status metrics

### Security Design

- **Enable Routing Intent on all hubs** — If using Secured Hubs, configure Routing Intent
  on every hub to avoid asymmetric routing
- **Design firewall rules before enabling Routing Intent** — Prevent outages from missing
  Allow rules
- **Use Azure Firewall Premium** for TLS inspection and IDPS in production
- **Implement firewall policy hierarchy** — Base policy for org-wide rules, child policies
  per hub or region
- **Log everything** — Enable structured logging on Azure Firewall (AZFWNetworkRule,
  AZFWApplicationRule, AZFWNatRule, AZFWDnsQuery)

### Migration from Traditional Hub-Spoke

**Planning phase:**

1. Inventory all VNets, peerings, UDRs, and NSGs in the existing hub-spoke
2. Map on-prem connections (VPN sites, ER circuits) and their configurations
3. Identify custom routing (UDRs) that may not translate directly to VWAN
4. Plan VWAN hub address space (non-overlapping with existing networks)
5. Decide on Routing Intent strategy (internet, private, or both)

**Migration steps:**

1. Deploy VWAN and hub(s) in target region(s)
2. Deploy gateways (VPN, ER) in the hub — this takes 20–30 minutes
3. Connect spoke VNets to the hub (can coexist with legacy peering temporarily)
4. Migrate VPN/ER connections — this is the cut-over step with potential downtime
5. Remove legacy hub VNet peerings and UDRs
6. Enable Routing Intent if using Secured Hub
7. Validate routing with effective routes and end-to-end connectivity tests

**Rollback considerations:**

- Keep the legacy hub-spoke config documented for rollback
- Consider running both in parallel during a transition window for critical workloads
- VPN sites can be moved back to a traditional VPN gateway if needed
- ExpressRoute circuits can be associated with one gateway at a time — plan the switchover

### Operational Runbook Essentials

- **Weekly:** Review BGP peer status across all hubs
- **Weekly:** Check VPN tunnel utilization and error counts
- **Monthly:** Validate effective routes against expected baseline
- **On change:** Always check effective routes before and after any VWAN configuration change
- **Alert on:** Tunnel down, BGP peer down, firewall SNAT exhaustion, hub throughput threshold

---

## Quick Reference: Key Limits

| Resource | Limit |
|---|---|
| Hubs per VWAN | 500 |
| VNet connections per hub | 500 |
| S2S VPN connections per hub | 1,000 |
| P2S concurrent connections per hub | 100,000 (depends on scale units) |
| ExpressRoute connections per hub | 8 |
| Hub throughput (aggregate) | Up to 50 Gbps |
| Static routes per route table | 1,000 |
| Route tables per hub | 20 |
| BGP peered NVAs per hub | Varies by NVA type |
| Inter-hub bandwidth | Determined by hub SKU |

> **Note:** Limits are subject to change. Always verify current limits in the
> [Azure subscription limits documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#virtual-wan-limits).

---

## Quick Reference: Key CLI Commands

```bash
# List all VWAN resources
az network vwan list --resource-group myRG

# List hubs in a VWAN
az network vhub list --resource-group myRG

# Show hub details (address space, routing state, provisioning state)
az network vhub show --resource-group myRG --name myHub

# List VNet connections
az network vhub connection list --resource-group myRG --vhub-name myHub

# List route tables
az network vhub route-table list --resource-group myRG --vhub-name myHub

# Show VPN gateway status
az network vpn-gateway show --resource-group myRG --name myHub-vpngw

# List VPN site connections and their status
az network vpn-gateway connection list --resource-group myRG --gateway-name myHub-vpngw

# Reset a VPN gateway (last resort troubleshooting)
az network vpn-gateway reset --resource-group myRG --name myHub-vpngw

# Show routing intent configuration
az network vhub routing-intent show --resource-group myRG --vhub-name myHub --name myRoutingIntent
```
