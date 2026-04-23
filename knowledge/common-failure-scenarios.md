# Common Azure Networking Failure Scenarios - SRE Knowledge Base

## Overview

This document catalogs common failure scenarios in Azure networking environments, their symptoms, root causes, and resolution steps. This knowledge is specifically valuable for automated SRE investigation of network-related incidents.

## Category 1: IP Forwarding Failures

### Scenario 1.1: Azure NIC IP Forwarding Disabled
- **Impact**: All transit traffic through the NVA is silently dropped
- **Symptoms**: Spoke-to-spoke traffic fails, on-prem to spoke traffic fails, but direct traffic to/from NVA works
- **Root Cause**: IP Forwarding setting disabled on the NVA's Azure NIC (can happen due to accidental change, IaC drift, or ARM deployment overwrite)
- **Detection**: `az network nic show -g <rg> -n <nic> --query enableIpForwarding` returns false
- **Resolution**: `az network nic update -g <rg> -n <nic> --ip-forwarding true`
- **Prevention**: Azure Policy to enforce IP Forwarding on tagged NICs; monitoring alert on NIC configuration changes

### Scenario 1.2: OS-Level IP Forwarding Disabled
- **Impact**: Same as 1.1 — transit traffic dropped
- **Symptoms**: Same as 1.1
- **Root Cause**: `net.ipv4.ip_forward` set to 0 in Linux (can happen after OS update, sysctl reset, or cloud-init re-run)
- **Detection**: SSH to NVA, run `sysctl net.ipv4.ip_forward`
- **Resolution**: `sudo sysctl -w net.ipv4.ip_forward=1` and persist in `/etc/sysctl.d/`
- **Prevention**: Use cloud-init or custom script extension to ensure setting persists

## Category 2: Route Table (UDR) Failures

### Scenario 2.1: Missing Default Route in Spoke
- **Impact**: Spoke traffic to on-premises or other spokes bypasses NVA
- **Symptoms**: Traffic works but is not inspected by firewall; security policy violations
- **Root Cause**: UDR 0.0.0.0/0 → NVA not present in spoke route table
- **Detection**: `az network nic show-effective-route-table` shows system default route instead of UDR
- **Resolution**: Add UDR 0.0.0.0/0 with next hop as NVA IP

### Scenario 2.2: Wrong Next Hop IP in UDR
- **Impact**: Traffic sent to wrong or non-existent destination
- **Symptoms**: Traffic black-holed (timeouts, no ICMP unreachable)
- **Root Cause**: NVA IP changed but UDR not updated; copy-paste error
- **Detection**: Compare UDR next hop with actual NVA private IP
- **Resolution**: Update UDR next hop to correct NVA IP

### Scenario 2.3: Route Table Not Associated to Subnet
- **Impact**: UDRs have no effect
- **Symptoms**: Traffic follows default Azure routing, bypasses NVA
- **Root Cause**: Route table created but not associated (common in IaC errors)
- **Detection**: Check subnet properties for route table association
- **Resolution**: Associate route table to the correct subnet

### Scenario 2.4: BGP Propagation Incorrectly Configured
- **Impact**: On spoke — on-premises routes bypass NVA; On GatewaySubnet — gateway breaks
- **Symptoms**: On spoke: direct routing to on-prem instead of through NVA. On GW: VPN/ER connectivity fails.
- **Root Cause**: Propagation enabled when should be disabled (spoke) or disabled when should be enabled (GW)
- **Detection**: Check route table propagation setting and effective routes
- **Resolution**: Toggle propagation setting appropriately

### Scenario 2.5: Summary Route on GatewaySubnet
- **Impact**: On-premises traffic to spokes bypasses NVA
- **Symptoms**: On-prem can reach spokes directly without firewall inspection
- **Root Cause**: GatewaySubnet UDR uses 10.0.0.0/8 instead of exact spoke prefixes
- **Detection**: Effective routes on gateway show peering routes (more specific) taking precedence
- **Resolution**: Replace summary route with exact spoke prefix routes

## Category 3: NSG Failures

### Scenario 3.1: NSG Blocking Legitimate Traffic
- **Impact**: Application connectivity failure
- **Symptoms**: Connection refused or timeout; works if NSG removed
- **Root Cause**: Deny rule with higher priority, or missing allow rule
- **Detection**: IP Flow Verify, NSG flow logs show denied flows
- **Resolution**: Add or modify NSG rules to allow required traffic

### Scenario 3.2: NSG Blocking Load Balancer Health Probes
- **Impact**: NVA/backend appears unhealthy, traffic not forwarded
- **Symptoms**: Load balancer shows 0% health; backend unreachable
- **Root Cause**: NSG missing rule to allow AzureLoadBalancer tag (source 168.63.129.16)
- **Detection**: LB health probe status shows down; NSG flow logs show denied probe traffic
- **Resolution**: Add inbound allow rule for AzureLoadBalancer service tag

### Scenario 3.3: NSG Applied to GatewaySubnet
- **Impact**: VPN/ExpressRoute gateway malfunction
- **Symptoms**: Gateway connectivity issues, tunnel failures
- **Root Cause**: NSG applied to GatewaySubnet (not supported)
- **Detection**: Check GatewaySubnet for NSG association
- **Resolution**: Remove NSG from GatewaySubnet

## Category 4: VPN/BGP Failures

### Scenario 4.1: VPN Tunnel Down — PSK Mismatch
- **Impact**: No connectivity between Azure and on-premises
- **Symptoms**: Connection status shows "Connecting" or "NotConnected"
- **Root Cause**: Pre-shared key doesn't match between Azure VPN GW and on-prem device
- **Detection**: VPN diagnostics show IKE negotiation failure
- **Resolution**: Verify and align PSK on both sides

### Scenario 4.2: BGP Session Not Established
- **Impact**: No dynamic routes exchanged; static routes may still work
- **Symptoms**: BGP peer status shows "Unknown" or "Connecting"
- **Root Cause**: Wrong BGP peer IP, wrong ASN, firewall blocking BGP (TCP 179)
- **Detection**: `az network vnet-gateway list-bgp-peer-status` shows non-connected peers
- **Resolution**: Verify BGP configuration (peer IP, ASN), ensure port 179 is allowed

### Scenario 4.3: BGP Route Not Propagated
- **Impact**: Partial connectivity; some destinations unreachable
- **Symptoms**: Specific prefixes missing from routing tables
- **Root Cause**: On-premises device not advertising prefix, or AS path filtering
- **Detection**: `az network vnet-gateway list-learned-routes` missing expected prefix
- **Resolution**: Check on-premises BGP configuration, route filters, route maps

### Scenario 4.4: VPN Gateway Overloaded
- **Impact**: Packet drops, increased latency
- **Symptoms**: Throughput below expected, intermittent failures
- **Root Cause**: Gateway SKU too small for traffic volume
- **Detection**: Gateway metrics show high utilization, packet drops
- **Resolution**: Upgrade gateway SKU

## Category 5: NVA Firewall (iptables) Failures

### Scenario 5.1: iptables FORWARD Chain Set to DROP
- **Impact**: All forwarded traffic blocked
- **Symptoms**: No traffic traverses NVA; direct NVA traffic works
- **Root Cause**: Default policy changed to DROP without corresponding ACCEPT rules
- **Detection**: `sudo iptables -L FORWARD` shows policy DROP with no ACCEPT rules
- **Resolution**: Add appropriate ACCEPT rules or change policy to ACCEPT

### Scenario 5.2: iptables Rules Flushed
- **Impact**: Either all traffic passes unfiltered or all traffic blocked (depending on default policy)
- **Symptoms**: Either security policy violations or total connectivity loss
- **Root Cause**: `iptables -F` command run (accidentally or by automation)
- **Detection**: `sudo iptables -L` shows only default policy rules
- **Resolution**: Restore rules from `/etc/iptables/rules.v4` or reconfigure

### Scenario 5.3: iptables Blocking Specific Traffic
- **Impact**: Specific flows fail while others work
- **Symptoms**: Partial connectivity — some sources/destinations work, others don't
- **Root Cause**: Specific deny rule in FORWARD chain
- **Detection**: `sudo iptables -L FORWARD -v -n` shows DROP rules with hit counters
- **Resolution**: Remove or modify the offending rule

## Category 6: VNet Peering Failures

### Scenario 6.1: Peering in Disconnected State
- **Impact**: No traffic between peered VNets
- **Symptoms**: Complete loss of connectivity between hub and spoke
- **Root Cause**: One side of peering deleted or misconfigured
- **Detection**: `az network vnet peering show` returns state "Disconnected"
- **Resolution**: Delete and recreate peering on both sides

### Scenario 6.2: Gateway Transit Not Configured
- **Impact**: Spoke can't use hub's VPN/ER gateway
- **Symptoms**: Spoke VMs can't reach on-premises
- **Root Cause**: "Allow gateway transit" (hub) or "Use remote gateways" (spoke) not enabled
- **Detection**: Check peering properties for gateway settings
- **Resolution**: Enable appropriate gateway transit settings on both sides of peering

## Category 7: Asymmetric Routing

### Scenario 7.1: Forward Through NVA, Return Bypasses NVA
- **Impact**: Stateful firewall drops return traffic
- **Symptoms**: Connection timeouts, TCP resets
- **Root Cause**: Missing UDR on GatewaySubnet or inconsistent route tables
- **Detection**: Trace forward and return paths independently
- **Resolution**: Ensure symmetric routing through consistent UDRs on all relevant subnets

## Category 8: Connection Monitor Alert Failures

### Scenario 8.1: All Connection Monitor Tests From One Spoke Fail
- **Impact**: Complete loss of monitored connectivity from one spoke
- **Symptoms**: All tests sourced from a specific spoke VM show ChecksFailedPercent = 100%
- **Root Cause**: Spoke routing failure (UDR detached, wrong next hop, missing route) or VNet peering disconnected
- **Detection**: Connection Monitor alert fires; check effective routes on spoke VM NIC
- **Resolution**: Fix spoke UDR (re-associate route table, correct next hop) or restore VNet peering

### Scenario 8.2: All Connection Monitor Tests Through One Hub Fail
- **Impact**: All traffic transiting through one hub's NVA is disrupted
- **Symptoms**: All tests whose path traverses hub NVA show failures
- **Root Cause**: NVA IP forwarding disabled (Azure NIC or OS level), NVA down, iptables blocking, LB health probes failing
- **Detection**: Check NVA NIC IP forwarding, LB health probe status, NVA iptables rules
- **Resolution**: Re-enable IP forwarding, fix iptables rules, restore LB health probes

### Scenario 8.3: Cross-Hub Connection Monitor Tests Fail
- **Impact**: Traffic between spoke11/12 and spoke21/22 fails
- **Symptoms**: Only cross-hub tests fail, intra-hub tests may still work
- **Root Cause**: VPN tunnel between hubs down, BGP not advertising routes, NVA not forwarding inter-hub traffic
- **Detection**: Check VPN connection status, BGP peer status, learned routes
- **Resolution**: Restore VPN connection, fix BGP configuration, verify NVA routing

### Scenario 8.4: Connection Monitor Tests to On-Premises Fail
- **Impact**: No connectivity between Azure spokes and on-premises
- **Symptoms**: All spoke-to-onprem tests fail; intra-Azure tests may work
- **Root Cause**: VPN tunnel to on-prem down, on-prem gateway issue, GatewaySubnet UDR misconfiguration, NVA not forwarding VPN traffic
- **Detection**: Check both VPN connections (hub1-to-onprem, hub2-to-onprem), BGP status, GatewaySubnet routes
- **Resolution**: Restore VPN connections, fix BGP, verify GatewaySubnet UDRs point to NVA

### Scenario 8.5: Connection Monitor RTT Spike Without Failure
- **Impact**: Degraded performance without total failure
- **Symptoms**: RoundTripTimeMs metric increases significantly but ChecksFailedPercent stays low
- **Root Cause**: NVA CPU/memory overload, suboptimal routing (hairpinning), congested path
- **Detection**: Check NVA VM metrics (CPU, memory), verify routing paths aren't unnecessarily long
- **Resolution**: Scale up NVA, optimize routing, investigate traffic patterns

## Investigation Playbook

### Step-by-Step Approach
1. **Identify affected traffic flow**: Source IP, destination IP, protocol, port
2. **Map the expected path**: Source → NSG → UDR → [NVA] → UDR → NSG → Destination
3. **Check at each hop**:
   - Effective routes (is routing correct?)
   - Effective NSG (is traffic allowed?)
   - NVA status (is it running, forwarding, allowing?)
4. **For VPN issues**: Connection status → BGP peer status → Learned routes → Advertised routes
5. **Collect evidence**: Effective routes, NSG flow logs, NVA logs, VPN diagnostics
6. **Correlate timing**: When did the failure start? Any recent changes? (Activity Log)
