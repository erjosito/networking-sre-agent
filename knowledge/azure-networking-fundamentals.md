# Azure Networking Fundamentals - SRE Knowledge Base

## Overview

This document summarizes core Azure networking concepts essential for troubleshooting and operating Azure network environments.

## Azure Virtual Networks (VNets)

- VNets are the fundamental building block of Azure networking
- VNets are scoped to a single Azure region and a single Azure subscription
- VNets have one or more address spaces (CIDR ranges)
- Subnets divide VNet address space into smaller segments
- **Subnets in Azure are NOT layer-2 broadcast domains** — they are purely a management and routing boundary
- All routing is performed by Azure NICs, not by traditional routers

## Packet Forwarding in Azure

- Azure uses Software-Defined Networking (SDN) — there are no physical switches or routers
- All VMs in a VNet see the same bogus MAC address (12:34:56:78:9a:bc) for ARP entries — Azure simulates L2 while being a purely L3 fabric
- The default gateway (first usable IP in each subnet, e.g., x.x.x.1) does not physically exist — it answers ARP but packets are routed by NICs
- Packets between VMs in the same subnet do NOT traverse any gateway — routing happens at the NIC level

## IP Addressing

- Azure NICs get their IP addresses from the Azure fabric via DHCP
- **Never configure IP addresses manually in the OS** — this breaks Azure SDN
- NICs can have multiple IP configurations (primary + secondary IPs)
- VMs can have multiple NICs (limited by VM size)

## IP Forwarding

- By default, Azure blocks packets from a VM unless sourced from its allocated IP (anti-spoofing)
- **IP Forwarding** on a NIC removes this restriction, allowing the VM to forward packets from other sources
- **Critical for NVAs**: Firewalls, routers, VPN appliances, and load balancers require IP Forwarding enabled
- IP Forwarding must be enabled both at the Azure NIC level AND in the guest OS
- **Common failure**: If IP Forwarding is disabled on an NVA NIC, all transit traffic is silently dropped

## Routing in Azure

### System Routes (Default)
Azure automatically creates routes for:
- VNet address space (next hop: VNet)
- Peered VNet address spaces (next hop: VNet peering)
- On-premises routes learned via VPN/ExpressRoute gateways (next hop: Virtual network gateway)
- Default route 0.0.0.0/0 (next hop: Internet)

### User-Defined Routes (UDRs)
- Created in Route Tables, which are associated to subnets
- Override system routes for matching prefixes using longest-prefix-match
- Common next hop types: Virtual appliance (IP), Virtual network gateway, VNet, Internet, None
- **Important**: UDRs with next hop "Virtual appliance" require the target VM to have IP Forwarding enabled

### Route Selection Priority
1. User-defined routes (highest priority)
2. BGP routes (from gateways)
3. System routes (lowest priority)
- Within same priority: longest prefix match wins

### Gateway Route Propagation
- Route tables have a setting to enable/disable BGP route propagation
- When disabled, routes learned from VPN/ExpressRoute gateways are NOT propagated to the subnet
- **Critical for NVA designs**: Spoke subnets typically disable gateway propagation to force traffic through NVA
- **Warning**: Never disable gateway propagation on the GatewaySubnet — this breaks gateway control plane

### Common routing issues
- Gateway route propagation is disabled in the route table applied to the GatewaySubnet
- Routing is asymmetric: one direction of the traffic is sent through the firewall NVA, but the other bypasses the NVA
- Routes in the route table applied to the GatewaySubnet do not match exactly the spoke prefixes but are more generic, consequently not overriding the spoke route injected by VNet peering into the GatewaySubnet (longest prefix match wins)

## Network Security Groups (NSGs)

### Basics
- NSGs contain inbound and outbound rules with priorities (100-65000, lower = higher priority)
- NSGs can be applied at subnet or NIC level (always enforced at NIC level)
- Default rules: allow all outbound, deny all inbound (except from VirtualNetwork tag)
- When NSGs are applied at both subnet and NIC, traffic must be allowed by BOTH

### Service Tags
- Named groups of IP addresses maintained by Microsoft (e.g., AzureStorage, AzureLoadBalancer)
- Can be region-scoped (e.g., AzureStorage.UKSouth)
- **VirtualNetwork tag** is wider than just the VNet — includes peered VNets and on-premises ranges

### Common NSG Issues
- Forgetting to allow return traffic (NSGs are stateful for established connections but can still cause issues)
- VirtualNetwork service tag allowing unexpected traffic from peered networks
- NSG on GatewaySubnet is NOT supported
- NSG blocking health probes from Azure Load Balancer (source: AzureLoadBalancer tag, 168.63.129.16)

## Load Balancing for NVAs

- Azure Load Balancer (ALB) is used to cluster NVAs for high availability
- ALB uses 5-tuple hash (src IP, dst IP, src port, dst port, protocol) for session affinity
- **Traffic symmetry**: ALB ensures forward and return traffic go to the same NVA instance
- Design pattern: Internal LB in front of NVAs for east-west/north-south traffic
- Health probes monitor NVA availability — if probe fails, traffic redirected to healthy instances
- **HA Ports rule**: Allows a single LB rule to cover all ports and protocols (required for NVA scenarios)

## Common Troubleshooting Approaches

1. **Check Effective Routes**: `az network nic show-effective-route-table` — shows actual routing decisions
2. **Check Effective NSG**: `az network nic list-effective-nsg` — shows combined NSG rules
3. **IP Flow Verify**: Network Watcher tool to test if traffic is allowed/denied
4. **Next Hop**: Network Watcher tool to determine next hop for a packet
5. **Connection Troubleshoot**: End-to-end connectivity test
6. **VPN Diagnostics**: Check gateway health, connection status, and BGP peer state
