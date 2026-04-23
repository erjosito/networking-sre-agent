# Azure ExpressRoute — Deep Dive for SRE

## 1. Overview

Azure ExpressRoute provides **private, dedicated connectivity** between on-premises networks and Azure datacenters. Traffic does **not** traverse the public internet, offering lower latency, higher reliability, and predictable throughput compared to site-to-site VPN.

### Connectivity Models

| Model | Description | Use Case |
|---|---|---|
| **CloudExchange Co-location** | Layer 2 or Layer 3 cross-connect at a colocation facility (e.g., Equinix, Megaport) | Enterprise with presence at a peering exchange |
| **Point-to-Point Ethernet** | Dedicated Layer 2 link from on-prem to Azure | Single-site, high-bandwidth requirements |
| **Any-to-Any (IPVPN)** | Integrate Azure into your MPLS WAN as another branch site | Multi-site enterprise with existing MPLS |
| **ExpressRoute Direct** | Dedicated 10G or 100G physical ports at a peering location | Massive ingress, regulatory isolation, MACsec |

### Peering Locations

ExpressRoute circuits are created at **peering locations** (physical meet-me points). Each peering location maps to a **geopolitical region** that determines which Azure regions are reachable with a Standard circuit. Premium SKU removes the geopolitical boundary restriction.

Key point: the peering location is **not** the same as an Azure region. A circuit at "Washington DC" peering location can reach Azure East US and other regions within the same geopolitical region.

---

## 2. Circuit Architecture

### Physical Redundancy

Every ExpressRoute circuit consists of **two independent BGP sessions** over **two physical connections** (primary and secondary). This is not optional — it is how Microsoft provisions the service.

```
On-Prem Router A ──── Primary Connection ────── Microsoft Enterprise Edge (MSEE-A)
On-Prem Router B ──── Secondary Connection ──── Microsoft Enterprise Edge (MSEE-B)
```

Both paths are **active-active** by default. Microsoft advertises the same routes on both paths with equal AS-path length. The customer CE routers perform ECMP load balancing unless AS-path prepending is configured.

### Peering Types

| Peering | Purpose | Address Space | Route Limit |
|---|---|---|---|
| **Azure Private Peering** | Access VNets (VMs, ILBs, private endpoints) | RFC 1918 or public IPs (NAT not required) | 4,000 routes (Standard), 10,000 (Premium) |
| **Microsoft Peering** | Access Microsoft 365, Dynamics 365, Azure PaaS public endpoints | Public IPs owned by customer (NAT required) | 200 routes |

> **Note:** Azure Public peering is **deprecated**. All public Azure service access should use Microsoft peering with route filters or Private Link over private peering.

### Circuit SKUs

| SKU | Scope | Key Difference |
|---|---|---|
| **Local** | Access only to Azure regions at or near the peering location | **No egress charges** — ideal for data-heavy workloads |
| **Standard** | Access to all Azure regions within the same geopolitical region | Normal egress billing |
| **Premium** | Access to all Azure regions globally | Higher route limits (10,000 private), Microsoft 365 support |

### Bandwidth Options

Available bandwidths: **50 Mbps, 100 Mbps, 200 Mbps, 500 Mbps, 1 Gbps, 2 Gbps, 5 Gbps, 10 Gbps**.

For ExpressRoute Direct: **10 Gbps or 100 Gbps** port pairs with the ability to create multiple circuits on the ports.

Bandwidth can be **upgraded** without downtime. **Downgrade** requires circuit recreation with most providers.

---

## 3. Routing

### BGP Peering

ExpressRoute uses **eBGP** between customer edge (CE) routers and Microsoft Enterprise Edge (MSEE) routers. Two BGP sessions per peering (primary + secondary).

- **Microsoft ASN:** 12076
- **Customer ASN:** Private (64512–65534) or public ASN
- **BGP Timers:** Microsoft uses hold time of 180 seconds (keepalive 60s). Mismatched timers negotiate to the lower value.

### Subnet Requirements for Peering

Each peering requires a **/30 subnet** for primary and secondary:

```
Primary:   /30 → .1 (MSEE), .2 (CE)
Secondary: /30 → .1 (MSEE), .2 (CE)
```

These subnets must **not** overlap with any VNet address space or other peering subnets.

### Route Advertisements

**From Microsoft (Private Peering):**
- All VNet address prefixes connected to the ExpressRoute gateway
- Default route (0.0.0.0/0) is **not** advertised by Microsoft

**From Customer (Private Peering):**
- On-premises routes advertised via BGP
- Microsoft validates that advertised routes are reachable

**Microsoft Peering:**
- Requires **route filters** to select which Microsoft service prefixes to receive
- Without a route filter, **no routes are advertised** to the customer on Microsoft peering

### Route Filters (Microsoft Peering)

Route filters are **mandatory** for Microsoft peering. They select BGP communities corresponding to Azure services/regions:

```bash
# Create a route filter
az network route-filter create \
  --name MyRouteFilter \
  --resource-group MyRG

# Add a rule for Azure Storage in East US
az network route-filter rule create \
  --filter-name MyRouteFilter \
  --resource-group MyRG \
  --name AllowStorageEastUS \
  --access Allow \
  --communities "12076:51004"

# Associate with Microsoft peering
az network express-route peering update \
  --circuit-name MyCircuit \
  --resource-group MyRG \
  --name MicrosoftPeering \
  --route-filter MyRouteFilter
```

### BGP Communities

Microsoft tags routes with **BGP communities** to identify the Azure region and service:

| Community | Service |
|---|---|
| `12076:51004` | Azure Storage — East US |
| `12076:51005` | Azure SQL — East US |
| `12076:51006` | Azure Storage — West US |
| `12076:52004` | All services — East US (regional community) |

Full list: Azure region BGP communities follow the pattern `12076:5xxxx` where the last digits encode region and service.

### AS Path Prepending

To influence **inbound** traffic toward a preferred path (primary vs. secondary):

```
route-map SECONDARY-PREPEND permit 10
  set as-path prepend 65001 65001 65001
!
router bgp 65001
  neighbor <MSEE-secondary-IP> route-map SECONDARY-PREPEND out
```

This makes the secondary path appear longer, causing Microsoft to prefer the primary path for return traffic.

### Route Limits

| Peering | Standard SKU | Premium SKU |
|---|---|---|
| Azure Private | 4,000 routes | 10,000 routes |
| Microsoft | 200 routes | 200 routes |

When limits are approached (at 75% and 100%), Microsoft generates **Resource Health alerts**. Exceeding the limit causes the **BGP session to drop** and routes are withdrawn.

---

## 4. ExpressRoute Gateway

The ExpressRoute virtual network gateway sits in a **GatewaySubnet** within a VNet and terminates the circuit connection.

### Gateway SKUs

| SKU | Max Circuits | Throughput (Gbps) | Connections per Circuit | Zone Redundant |
|---|---|---|---|---|
| **Standard / ErGw1Az** | 4 | ~1 | 1 | ErGw1Az: Yes |
| **HighPerformance / ErGw2Az** | 8 | ~2 | 1 | ErGw2Az: Yes |
| **UltraPerformance / ErGw3Az** | 16 | ~10 | 1 | ErGw3Az: Yes |
| **ErGwScale (preview)** | 16 | 1–40 (scalable) | 1 | Yes |

> **SRE Tip:** Gateway throughput is often the bottleneck, not the circuit. A 10 Gbps circuit with a Standard gateway caps at ~1 Gbps through the gateway.

### GatewaySubnet Sizing

- Minimum: **/27** (recommended by Microsoft)
- Use **/27** for future-proofing (supports coexistence with VPN Gateway)
- **Do not** place NSGs on the GatewaySubnet — this breaks gateway communication

### FastPath

FastPath bypasses the gateway for **data-plane traffic**, sending packets directly from the MSEE to VNet VMs. The gateway is still used for control-plane (route exchange).

**Requirements:**
- **UltraPerformance (ErGw3Az)** or **ErGwScale** gateway SKU
- Enabled per connection

**Limitations (FastPath does NOT support):**
- VNet peering (traffic to peered VNets still goes through gateway)
- UDRs on GatewaySubnet
- Private Link / Private Endpoints (supported since late 2023 on ErGw3Az)
- Basic Load Balancer

```bash
# Enable FastPath on a connection
az network vpn-connection update \
  --name MyERConnection \
  --resource-group MyRG \
  --express-route-gateway-bypass true
```

### Connecting Circuit to Gateway

```bash
# Create the connection
az network vpn-connection create \
  --name ER-Connection \
  --resource-group MyRG \
  --vnet-gateway1 MyErGateway \
  --express-route-circuit2 /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/expressRouteCircuits/MyCircuit \
  --routing-weight 10
```

The `routing-weight` (0–32000) is used when multiple circuits connect to the same gateway — higher weight is preferred.

---

## 5. ExpressRoute Global Reach

Global Reach connects **two ExpressRoute circuits** together so that on-premises sites in different regions can communicate through the Microsoft backbone instead of the public internet.

```
Site A (Tokyo) ←→ ExpressRoute Circuit A ←→ Microsoft Backbone ←→ ExpressRoute Circuit B ←→ Site B (London)
```

### Configuration

```bash
az network express-route peering connection create \
  --circuit-name CircuitA \
  --peering-name AzurePrivatePeering \
  --resource-group MyRG \
  --name GlobalReachConnection \
  --peer-circuit /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/expressRouteCircuits/CircuitB \
  --address-prefix 10.0.1.0/29
```

### Limitations

- Not available in **all** peering locations (check docs for supported locations)
- Requires **Premium** or **Standard** SKU (not Local)
- Both circuits must be in **Provisioned** state
- No transitive routing through a VNet — Global Reach is circuit-to-circuit

---

## 6. ExpressRoute Direct

ExpressRoute Direct provides **dedicated physical ports** (10G or 100G) at Microsoft peering locations. You own the port pair and can create multiple circuits on top.

### Key Features

| Feature | Benefit |
|---|---|
| **MACsec encryption** | Layer 2 encryption on the physical links |
| **Multiple circuits** | Carve multiple logical circuits from the same port pair |
| **Higher bandwidth** | Support for 40 Gbps and 100 Gbps circuits |
| **Direct control** | No service-provider middleman for provisioning |

### MACsec Configuration

MACsec encrypts traffic between your edge router and the Microsoft edge at Layer 2:

```bash
# Configure MACsec on Direct ports
az network express-route port update \
  --name MyDirectPort \
  --resource-group MyRG \
  --macsec-ckn-secret-identifier "https://myvault.vault.azure.net/secrets/ckn-secret" \
  --macsec-cak-secret-identifier "https://myvault.vault.azure.net/secrets/cak-secret" \
  --macsec-cipher GcmAes256
```

### Provisioning Circuits on Direct

```bash
# Create a circuit on Direct ports
az network express-route create \
  --name DirectCircuit1 \
  --resource-group MyRG \
  --bandwidth 10 Gbps \
  --express-route-port /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/expressRoutePorts/MyDirectPort \
  --sku-family MeteredData \
  --sku-tier Premium
```

---

## 7. High Availability

### Design Patterns

#### Pattern 1: Dual Circuits (Recommended for Production)

```
On-Prem ──── Circuit A (Peering Location 1) ──── Azure
On-Prem ──── Circuit B (Peering Location 2) ──── Azure
```

Both circuits connect to the same VNet gateway. Use BGP route weight or AS-path prepending to establish primary/backup.

#### Pattern 2: Zone-Redundant Gateway

Use **ErGw1Az / ErGw2Az / ErGw3Az** SKUs. These deploy gateway instances across Availability Zones, surviving a single zone failure.

```bash
# Create zone-redundant gateway (requires Standard public IP)
az network public-ip create \
  --name ErGw-PIP \
  --resource-group MyRG \
  --sku Standard \
  --zone 1 2 3

az network vnet-gateway create \
  --name MyErGateway \
  --resource-group MyRG \
  --vnet MyVNet \
  --gateway-type ExpressRoute \
  --sku ErGw2Az \
  --public-ip-addresses ErGw-PIP
```

#### Pattern 3: ExpressRoute + VPN Failover (Coexistence)

Deploy both an ExpressRoute gateway and a VPN gateway in the same GatewaySubnet. ExpressRoute is primary; VPN tunnel activates if ExpressRoute goes down.

**Key considerations:**
- Both gateways can coexist in the same VNet
- VPN gateway uses BGP with a **different ASN** from ExpressRoute
- ExpressRoute routes are preferred over VPN routes (more specific or higher weight)
- VPN provides ~1.25 Gbps max — only suitable as emergency failover

### BFD (Bidirectional Forwarding Detection)

BFD provides **sub-second failover** between primary and secondary paths. Enabled by default on private peering for new circuits.

- BFD interval: ~300ms
- Detects link failure faster than BGP hold timer (180s)
- Supported on MSEE side — must also be enabled on customer CE routers

```
! Enable BFD on CE router (Cisco IOS-XE example)
router bgp 65001
  neighbor 10.0.0.1 fall-over bfd
!
interface GigabitEthernet0/0
  bfd interval 300 min_rx 300 multiplier 3
```

### Multi-Site Resilience

For maximum resilience, use **four connections** across two peering locations:

```
Site A → Circuit A (Location 1) → Primary + Secondary → Azure
Site A → Circuit B (Location 2) → Primary + Secondary → Azure
```

This survives: single link failure, single MSEE failure, single peering location failure.

---

## 8. Common Failure Scenarios

### 8.1 Circuit Not in "Provisioned" State

**Symptom:** Circuit shows `ServiceProviderProvisioningState: NotProvisioned` or `Provisioning`.

**Root Cause:** The connectivity provider has not completed their side of provisioning.

**Diagnosis:**
```bash
az network express-route show \
  --name MyCircuit \
  --resource-group MyRG \
  --query "{state:circuitProvisioningState, providerState:serviceProviderProvisioningState}"
```

**Resolution:**
- If `NotProvisioned`: Provide the **service key** to the connectivity provider to initiate provisioning
- If `Provisioning`: Wait for provider to complete; contact provider support if prolonged
- Circuit must be `Provisioned` before peering configuration works

### 8.2 BGP Session Down

**Symptoms:** No routes learned, traffic blackholed, circuit metrics show BGP availability at 0%.

**Common Causes:**

1. **ARP failure** — Layer 2 connectivity issue. Check ARP tables:
   ```bash
   az network express-route get-arp-table \
     --name MyCircuit \
     --resource-group MyRG \
     --peering-name AzurePrivatePeering \
     --path primary
   ```
   Empty ARP table = Layer 2 problem (VLAN mismatch, physical link down, provider issue).

2. **MTU issues** — ExpressRoute supports **1500-byte MTU** on the peering link. BGP uses TCP (port 179) which can be affected by MTU problems. Ensure no intermediate device truncates below 1500.

3. **BGP timer mismatch** — If CE router hold time is set too low, sessions may flap. Microsoft uses 180s hold / 60s keepalive.

4. **Wrong IP configuration** — Verify the /30 peering subnet IPs match exactly what Microsoft provisioned.

5. **ACL/Firewall blocking TCP 179** — Ensure BGP (TCP 179) and BFD (UDP 3784/3785) are allowed on CE router interfaces.

### 8.3 Asymmetric Routing

**Symptom:** Traffic flows out one path (e.g., primary) but returns via the other (secondary), causing stateful firewalls to drop return traffic.

**Root Cause:** Both paths have equal BGP attributes, and CE/MSEE make different path selections.

**Resolution:**
- Use **AS-path prepending** on the less-preferred path
- Use **BGP local-preference** on CE routers
- Configure stateful firewalls for asymmetric flow handling, or use flow-state sync between firewall instances

### 8.4 Route Limits Exceeded

**Symptom:** BGP session tears down. Routes disappear. Circuit metrics show route count at or above the limit.

**Diagnosis:**
```bash
az network express-route get-route-table \
  --name MyCircuit \
  --resource-group MyRG \
  --peering-name AzurePrivatePeering \
  --path primary
```

**Resolution:**
- Summarize routes on the CE router (aggregate more-specific routes)
- Upgrade to **Premium** SKU for 10,000-route limit on private peering
- For Microsoft peering (200 max): refine route filters to only needed prefixes

### 8.5 Missing Route Filters on Microsoft Peering

**Symptom:** Microsoft peering is configured, BGP session is up, but **no routes are received** from Microsoft.

**Root Cause:** Route filters are mandatory on Microsoft peering. Without them, Microsoft advertises zero routes.

**Resolution:**
```bash
# Verify route filter association
az network express-route peering show \
  --circuit-name MyCircuit \
  --resource-group MyRG \
  --name MicrosoftPeering \
  --query "routeFilter"
```

Create and associate a route filter with appropriate BGP community rules.

### 8.6 Gateway Performance Degradation

**Symptom:** Throughput through ExpressRoute is much lower than the circuit bandwidth. High latency or packet drops at the gateway.

**Root Cause:** Gateway SKU is undersized for the workload.

**Diagnosis:**
```
// KQL — Gateway throughput metric
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "ExpressRouteGatewayBitsPerSecond"
| where Resource contains "MYERGATEWAY"
| summarize AvgThroughput = avg(Average) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

**Resolution:**
- Upgrade gateway SKU: Standard → HighPerformance → UltraPerformance
- For Az SKUs: ErGw1Az → ErGw2Az → ErGw3Az
- Enable **FastPath** (requires ErGw3Az) to bypass the gateway data plane

### 8.7 FastPath Not Working

**Symptom:** FastPath is enabled but traffic still routes through the gateway (seen as gateway bottleneck remaining).

**Common Causes:**
- Gateway SKU is not **ErGw3Az / UltraPerformance** — FastPath requires these
- Traffic is destined to a **peered VNet** — FastPath does not support VNet peering transit
- Traffic targets a **Private Endpoint** — check if your gateway supports it (ErGw3Az since late 2023)
- **Basic Load Balancer** in the path — not supported with FastPath
- **UDRs on GatewaySubnet** — not supported

### 8.8 ExpressRoute + VPN Coexistence Routing Conflicts

**Symptom:** In a coexistence setup, traffic takes the VPN path instead of ExpressRoute, or routing loops occur.

**Root Cause:** Overlapping route advertisements or misconfigured route preferences.

**Resolution:**
- ExpressRoute routes should be **more specific** or have **higher weight** than VPN routes
- Verify VPN BGP ASN is different from ExpressRoute customer ASN
- Check effective routes on the NIC of affected VMs:
  ```bash
  az network nic show-effective-route-table \
    --name MyNIC \
    --resource-group MyRG
  ```

### 8.9 MTU / Fragmentation Issues

**Symptom:** Large packets (e.g., NFS, database backups) fail or perform poorly. Small packets (ping) work fine.

**Root Cause:** The end-to-end MTU path through ExpressRoute is **1500 bytes**. If applications send jumbo frames or don't handle fragmentation, large payloads break.

**Diagnosis:**
```bash
# Test from on-prem with DF bit set
ping -M do -s 1472 <Azure-VM-IP>
# On Windows:
ping -f -l 1472 <Azure-VM-IP>
```

If 1472 bytes fails (1472 + 28 ICMP/IP header = 1500), there's an MTU problem in the path.

**Resolution:**
- Set MSS clamping on CE routers: `ip tcp adjust-mss 1436`
- Ensure no devices inject additional headers (GRE, VXLAN) without reducing effective MTU
- For IPsec over ExpressRoute, account for ESP overhead (~50-70 bytes)

### 8.10 Circuit Bandwidth Saturation

**Symptom:** Increased latency and packet loss during peak hours. Circuit metrics show sustained utilization near the provisioned bandwidth.

**Diagnosis:**
```
// KQL — Circuit ingress/egress bits
AzureMetrics
| where MetricName in ("BitsInPerSecond", "BitsOutPerSecond")
| where Resource contains "MYCIRCUIT"
| summarize MaxIngress=max(iff(MetricName=="BitsInPerSecond", Maximum, 0)),
            MaxEgress=max(iff(MetricName=="BitsOutPerSecond", Maximum, 0))
  by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

**Resolution:**
- Upgrade circuit bandwidth (usually non-disruptive for upgrades)
- Implement QoS on CE routers to prioritize critical traffic
- Distribute workloads across multiple circuits
- Consider ExpressRoute Direct for 40G/100G options

---

## 9. Troubleshooting Toolkit

### ARP Table Verification

Validates Layer 2 connectivity between CE and MSEE:

```bash
# Check ARP on primary path
az network express-route get-arp-table \
  --name MyCircuit --resource-group MyRG \
  --peering-name AzurePrivatePeering --path primary

# Check ARP on secondary path
az network express-route get-arp-table \
  --name MyCircuit --resource-group MyRG \
  --peering-name AzurePrivatePeering --path secondary
```

**Expected:** You should see the MSEE IP (.1 of the /30) with a valid MAC address. Missing entry = Layer 2 failure.

### Route Table Inspection

Shows routes learned/advertised on each peering path:

```bash
az network express-route get-route-table \
  --name MyCircuit --resource-group MyRG \
  --peering-name AzurePrivatePeering --path primary
```

**Check for:**
- Expected VNet prefixes in routes learned from Microsoft
- Your on-prem prefixes in routes advertised to Microsoft
- Route count approaching limits

### BGP Peering Diagnostics

```bash
# Full circuit peering details
az network express-route peering show \
  --circuit-name MyCircuit --resource-group MyRG \
  --name AzurePrivatePeering

# Circuit overall state
az network express-route show \
  --name MyCircuit --resource-group MyRG \
  --query "{state:circuitProvisioningState, providerState:serviceProviderProvisioningState, peerings:peerings[].{name:name, state:state}}"
```

### Key Metrics (Azure Monitor)

**Circuit Metrics:**

| Metric | What It Shows |
|---|---|
| `BitsInPerSecond` / `BitsOutPerSecond` | Circuit bandwidth utilization |
| `BgpAvailability` | BGP session uptime (target: 100%) |
| `ArpAvailability` | ARP resolution success (target: 100%) |
| `GlobalReachBitsInPerSecond` | Global Reach traffic (if configured) |

**Gateway Metrics:**

| Metric | What It Shows |
|---|---|
| `ExpressRouteGatewayBitsPerSecond` | Throughput through the gateway |
| `ExpressRouteGatewayCountOfRoutesAdvertisedToPeer` | Routes sent to MSEE |
| `ExpressRouteGatewayCountOfRoutesLearnedFromPeer` | Routes received from MSEE |
| `ExpressRouteGatewayCpuUtilization` | Gateway CPU (high = SKU upgrade needed) |

### KQL Queries for Log Analytics

```kql
// BGP availability trend over 24 hours
AzureMetrics
| where MetricName == "BgpAvailability"
| where Resource contains "MYCIRCUIT"
| summarize AvgBgp = avg(Average) by bin(TimeGenerated, 15m)
| where AvgBgp < 100
| order by TimeGenerated desc

// Gateway CPU utilization spikes
AzureMetrics
| where MetricName == "ExpressRouteGatewayCpuUtilization"
| where Resource contains "MYERGATEWAY"
| summarize MaxCpu = max(Maximum), AvgCpu = avg(Average) by bin(TimeGenerated, 5m)
| where MaxCpu > 80
| order by TimeGenerated desc

// Route count changes (detect route churn)
AzureMetrics
| where MetricName == "ExpressRouteGatewayCountOfRoutesLearnedFromPeer"
| where Resource contains "MYERGATEWAY"
| summarize RouteCount = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

### Connection Monitor with ExpressRoute

Use **Network Watcher → Connection Monitor** to set up continuous probes:

```bash
# Create a test to monitor ExpressRoute reachability
az network watcher connection-monitor create \
  --name ER-Monitor \
  --resource-group NetworkWatcherRG \
  --location eastus \
  --test-group-name ER-Test \
  --endpoint-source-name OnPremVM \
  --endpoint-source-resource-id /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/OnPremVM \
  --endpoint-dest-name AzureVM \
  --endpoint-dest-address 10.1.0.4 \
  --test-config-name TCPTest \
  --protocol Tcp \
  --tcp-port 443 \
  --threshold-round-trip-time 100 \
  --threshold-failed-percent 5
```

### Effective Routes Check

When troubleshooting VM reachability, always check effective routes on the NIC:

```bash
az network nic show-effective-route-table \
  --name MyVMNic --resource-group MyRG --output table
```

Look for:
- `VirtualNetworkGateway` source for on-prem routes
- Conflicting UDRs that might override ExpressRoute-learned routes
- `0.0.0.0/0` routes that might be hairpinning traffic unexpectedly

---

## 10. Best Practices

### Circuit Redundancy

- **Production workloads:** Deploy **two circuits** at **different peering locations**
- Connect both circuits to the **same gateway** (or separate gateways in paired regions)
- Use **routing-weight** on connections to prefer one circuit over another
- Test failover regularly by disabling one circuit in non-prod

### Gateway Sizing

- Match the gateway SKU to your **actual throughput needs**, not just the circuit bandwidth
- ErGw2Az (HighPerformance) is the minimum for most production workloads
- ErGw3Az (UltraPerformance) if you need FastPath or >2 Gbps throughput
- Monitor `ExpressRouteGatewayCpuUtilization` — sustained >80% means upgrade is needed

### Monitoring Checklist

Set up alerts for:

| Alert | Condition | Severity |
|---|---|---|
| BGP Availability | < 100% for 5 min | Critical (Sev 0) |
| ARP Availability | < 100% for 5 min | Critical (Sev 0) |
| Circuit Ingress | > 80% of provisioned bandwidth for 15 min | Warning (Sev 2) |
| Circuit Egress | > 80% of provisioned bandwidth for 15 min | Warning (Sev 2) |
| Gateway CPU | > 80% for 15 min | Warning (Sev 2) |
| Route Count | > 75% of limit | Warning (Sev 2) |

```bash
# Example: Alert on BGP availability drop
az monitor metrics alert create \
  --name "ER-BGP-Down" \
  --resource-group MyRG \
  --scopes "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/expressRouteCircuits/MyCircuit" \
  --condition "avg BgpAvailability < 100" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --severity 0 \
  --action-group "/subscriptions/{sub}/resourceGroups/{rg}/providers/microsoft.insights/actionGroups/SRE-Oncall"
```

### Disaster Recovery Patterns

**Active-Active Across Regions:**
```
On-Prem → Circuit A → Gateway A → VNet (Region 1) ←→ VNet Peering / Global VNet Peering ←→ VNet (Region 2) ← Gateway B ← Circuit B ← On-Prem
```

**Active-Passive with VPN Backup:**
```
On-Prem → ExpressRoute Circuit → ER Gateway (primary)
On-Prem → S2S VPN → VPN Gateway (backup, lower route weight)
```

### IP Address Planning

- Reserve dedicated **/30 subnets** for each peering (primary + secondary) — four /30s per circuit with both peerings
- Use a separate IP range for peering subnets, not overlapping with VNet or on-prem address space
- For Microsoft peering NAT: plan public IP allocation carefully — Microsoft validates ownership
- Document all peering IPs in a central IPAM; these are easy to lose track of across multiple circuits

### Operational Runbook Essentials

Every SRE team managing ExpressRoute should maintain runbooks for:

1. **Circuit failover test** — Procedure to disable/enable a circuit and validate traffic shifts
2. **Provider escalation** — Contact info, service keys, and circuit IDs for each connectivity provider
3. **Route table baseline** — Snapshot of expected routes for comparison during incidents
4. **Gateway upgrade** — Step-by-step for gateway SKU changes (triggers brief connectivity loss)
5. **Emergency VPN activation** — Process to bring up a pre-configured VPN tunnel if all circuits fail

---

## Quick Reference: Key CLI Commands

```bash
# Circuit status
az network express-route show -n {circuit} -g {rg} -o table

# List all peerings
az network express-route peering list --circuit-name {circuit} -g {rg} -o table

# ARP table
az network express-route get-arp-table -n {circuit} -g {rg} --peering-name AzurePrivatePeering --path primary

# Route table
az network express-route get-route-table -n {circuit} -g {rg} --peering-name AzurePrivatePeering --path primary

# Gateway details
az network vnet-gateway show -n {gateway} -g {rg} -o table

# Effective routes on NIC
az network nic show-effective-route-table -n {nic} -g {rg} -o table

# Route filter rules
az network route-filter rule list --filter-name {filter} -g {rg} -o table

# Circuit metrics (last 1 hour)
az monitor metrics list \
  --resource "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/expressRouteCircuits/{circuit}" \
  --metric "BgpAvailability,ArpAvailability,BitsInPerSecond,BitsOutPerSecond" \
  --interval PT5M --start-time (Get-Date).AddHours(-1).ToString("o")
```
