# VPN and ExpressRoute Connectivity - SRE Knowledge Base

## Overview

Azure provides two native mechanisms for connecting Azure VNets to on-premises networks: IPsec VPN (site-to-site) and ExpressRoute. This document covers operational knowledge for troubleshooting and managing these connections.

## Azure VPN Gateway

### Architecture
- Deployed in a dedicated **GatewaySubnet** (minimum /27 recommended)
- Only one VPN gateway per VNet
- Can coexist with ExpressRoute gateway in the same GatewaySubnet
- **No NSGs allowed on GatewaySubnet**
- Deployment modes:
  - **Active/Passive**: Single public IP, automatic failover (~60-90s)
  - **Active/Active**: Two public IPs, two instances, faster failover (~10-15s). **Recommended.**

### Resource Model
- **Virtual Network Gateway (VNG)**: The VPN gateway resource in Azure
- **Local Network Gateway (LNG)**: Represents the on-premises VPN device (public IP, BGP ASN, on-prem prefixes)
- **Connection**: Links VNG to LNG with shared key, protocol settings, and BGP configuration

### VPN Routing: Static vs Dynamic (BGP)

#### Static Routing
- On-premises prefixes configured in the LNG
- Routes programmed regardless of tunnel state — **can cause black-holes if tunnel is down**
- Does not support active/active on-premises devices
- Simpler but less resilient

#### Dynamic Routing (BGP)
- BGP peering between Azure VNG and on-premises device
- Routes only present when tunnel is up and BGP session established
- Supports all redundancy scenarios including active/active on both sides
- **Recommended for production environments**

### BGP Configuration Details

- Each Azure VNG instance has a BGP IP address (shown in gateway properties)
- BGP IPs are from the GatewaySubnet range (assigned by Azure, NOT user-configurable in most cases)
- Default Azure VPN Gateway ASN: **65515** (configurable)
- On-premises device must peer with BOTH instances for full redundancy
- **APIPA addresses** (169.254.21.x/169.254.22.x) can be used for BGP over IPsec tunnels

### BGP Route Exchange
- Azure VNG advertises all VNet and spoke prefixes to on-premises
- On-premises device advertises its local prefixes to Azure
- Routes are injected as "Virtual network gateway" type in effective routes
- In hub-spoke: gateway transit propagates routes to spoke VNets

### VPN Troubleshooting

| Symptom | Likely Cause | Action |
|---------|-------------|--------|
| Tunnel down | Shared key mismatch | Verify PSK on both sides |
| Tunnel down | IKE/IPsec policy mismatch | Check phase 1/2 parameters |
| Tunnel up, no traffic | Missing routes (static) | Verify LNG prefix configuration |
| Tunnel up, no traffic | BGP not established | Check BGP peer IPs and ASNs |
| Intermittent connectivity | MTU issues | Test with smaller packets, check MSS clamping |
| Asymmetric routing | Multiple tunnels without BGP | Enable BGP for proper path selection |
| Slow throughput | Gateway SKU too small | Upgrade gateway SKU |
| BGP flapping | Unstable underlay (Internet) | Check ISP connectivity, consider ExpressRoute |

### VPN Diagnostic Commands

```bash
# Check gateway status
az network vnet-gateway show -g <rg> -n <gw-name> --query 'provisioningState'

# List connections and their status
az network vpn-connection list -g <rg> --query '[].{name:name, status:connectionStatus}'

# Show connection details
az network vpn-connection show -g <rg> -n <conn-name>

# Check BGP peer status
az network vnet-gateway list-bgp-peer-status -g <rg> -n <gw-name>

# Check learned BGP routes
az network vnet-gateway list-learned-routes -g <rg> -n <gw-name>

# Check advertised routes to a specific peer
az network vnet-gateway list-advertised-routes -g <rg> -n <gw-name> --peer <peer-ip>

# VPN connection troubleshoot (Network Watcher)
az network watcher troubleshooting start -g <rg> --resource <connection-id> --resource-type vpnConnection --storage-account <storage> --storage-path <container-url>
```

## Multi-Hub VPN Design

### Hub-to-Hub VPN
- When hubs are in different regions, VPN S2S or VNet peering connects them
- BGP enables dynamic route exchange between hubs
- Each hub advertises its own VNet + spoke prefixes

### On-Premises to Multi-Hub
- On-premises can connect to multiple hub VPN gateways
- BGP AS path determines preferred path
- Careful ASN planning required to avoid loops
- **AS path prepending** can influence traffic flow

### Traffic Through NVA
- On-premises traffic destined for spokes must traverse the hub NVA
- GatewaySubnet UDRs point spoke prefixes to NVA IP
- NVA must have routes back to on-premises (via gateway or default route)
- **Critical**: Ensure symmetric routing — forward and return paths through same NVA

## Common Connectivity Patterns

### VPN + NVA in Hub
```
On-Premises → VPN Tunnel → VPN GW → (UDR) → NVA → (UDR) → Spoke VM
Spoke VM → (UDR) → NVA → (routing) → VPN GW → VPN Tunnel → On-Premises
```

### Key Requirements
1. GatewaySubnet route table: spoke prefixes → NVA IP, BGP propagation ON
2. NVA subnet route table: on-prem prefixes → VPN GW (or allow BGP propagation)
3. Spoke route table: 0.0.0.0/0 → NVA IP, BGP propagation OFF
4. NVA: IP Forwarding enabled, firewall rules allowing traffic
5. NVA: OS-level IP forwarding enabled (net.ipv4.ip_forward=1)
