# Hub-and-Spoke Network Topology - SRE Knowledge Base

## Overview

The hub-and-spoke topology is the most common Azure network design. It provides centralized connectivity and security services while allowing workloads to be distributed across multiple spoke VNets and subscriptions.

## Architecture Concepts

### Hub VNet
- Central VNet containing shared services: firewalls, VPN/ExpressRoute gateways, DNS
- All traffic between spokes and to/from on-premises transits through the hub
- Contains the GatewaySubnet for VPN/ExpressRoute gateways
- Contains a dedicated subnet for firewall/NVA appliances

### Spoke VNets
- Contain workload VMs and services
- Peered to the hub VNet (not to each other by default)
- Can be in different subscriptions from the hub
- Traffic to other spokes or on-premises is routed through the hub NVA/firewall

### VNet Peering
- Connects hub and spoke VNets
- Non-transitive by default — spoke-to-spoke traffic requires routing through the hub
- Settings that must be enabled:
  - **Allow forwarded traffic**: On both hub and spoke peerings
  - **Allow gateway transit**: On the hub side (shares gateway with spokes)
  - **Use remote gateways**: On the spoke side (uses hub's gateway)

## Routing in Hub-and-Spoke

### Spoke Route Tables
- Default route (0.0.0.0/0) → NVA/firewall IP in hub
- On-premises routes → NVA/firewall IP in hub
- Other spoke prefixes → NVA/firewall IP in hub
- **Disable BGP route propagation** to force all traffic through NVA
- Local VNet prefix is automatically handled (system route)

### Hub GatewaySubnet Route Table
- Must have **BGP route propagation ENABLED** (required for gateway control plane)
- UDRs for each spoke prefix → NVA/firewall IP
- **UDRs must match EXACTLY the spoke VNet prefixes** — summary routes won't override the more specific system routes from peering
- Do NOT add routes covering the firewall subnet or gateway subnet

### Hub NVA/Firewall Subnet Route Table
- May need routes for spoke prefixes if NVA needs to reach spokes
- Default route to Internet if NVA handles egress
- Consider asymmetric routing risks with active/active NVA deployments

## Multi-Hub Designs

### Dual Hub (Multi-Region or Multi-Segment)
- Two hub VNets, each with own set of spokes
- Hubs connected via VNet peering or VPN
- Each hub has its own NVA and gateway
- **Inter-hub traffic**: Requires explicit routing between hubs
- Common failure: Missing routes between hubs causing traffic black-holes

### Design Considerations
- Hub-to-hub peering does NOT automatically share gateway routes
- If using BGP, each hub's gateway advertises its local VNet and spoke prefixes
- NVAs in each hub must have routes to the other hub's spokes
- **UDR consistency is critical** — mismatched routes between hubs cause asymmetric routing

## Common Failures and Troubleshooting

### Peering Issues
| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| Spoke can't reach on-premises | "Use remote gateways" not enabled on spoke peering | Enable on spoke peering |
| Spoke can't reach on-premises | "Allow gateway transit" not enabled on hub peering | Enable on hub peering |
| Spoke-to-spoke traffic fails | Missing UDR to route through NVA | Add UDR for destination spoke prefix via NVA |
| Spoke-to-spoke traffic fails | NVA not forwarding traffic | Check iptables/firewall rules on NVA, check IP Forwarding |

### Routing Issues
| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| Traffic bypasses NVA | BGP route propagation enabled on spoke | Disable propagation on spoke route table |
| Gateway can't reach spokes | Missing UDR on GatewaySubnet | Add spoke prefix routes pointing to NVA |
| On-prem can't reach spoke | UDR on GatewaySubnet uses summary route | Use exact spoke prefix match |
| Asymmetric routing | Active/active NVA with stateful inspection | Use Azure LB with HA ports for NVA clustering |
| Black-holed traffic | UDR points to NVA that is down | Check NVA health, LB health probes |

### NVA Issues
| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| NVA not forwarding | IP Forwarding disabled on NIC | Enable IP Forwarding in Azure portal/CLI |
| NVA not forwarding | OS-level forwarding disabled | Enable net.ipv4.ip_forward=1 in OS |
| NVA dropping traffic | Firewall rules blocking | Check iptables/NVA security policy |
| NVA overloaded | Undersized VM or too many flows | Scale up VM size or add NVA instances behind LB |

## Azure CLI Commands for Diagnostics

```bash
# Check effective routes on a NIC
az network nic show-effective-route-table -g <rg> -n <nic-name>

# Check VNet peering status
az network vnet peering list -g <rg> --vnet-name <vnet>

# Check peering details
az network vnet peering show -g <rg> --vnet-name <vnet> -n <peering-name>

# Verify route table configuration
az network route-table show -g <rg> -n <rt-name>
az network route-table route list -g <rg> --route-table-name <rt-name>

# Check IP forwarding on NIC
az network nic show -g <rg> -n <nic-name> --query 'enableIpForwarding'

# Network Watcher next hop test
az network watcher show-next-hop -g <rg> --vm <vm-name> --source-ip <src> --dest-ip <dst>
```
