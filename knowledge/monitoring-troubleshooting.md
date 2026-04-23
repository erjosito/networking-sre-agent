# Monitoring and Troubleshooting Azure Networks - SRE Knowledge Base

## Overview

This document covers tools and methodologies for monitoring and troubleshooting Azure network environments.

## Azure Network Watcher

Network Watcher is the primary suite of network diagnostic tools in Azure.

### Key Tools

| Tool | Purpose | When to Use |
|------|---------|-------------|
| **IP Flow Verify** | Tests if a packet is allowed/denied by NSG | Verify NSG rules for specific traffic |
| **Next Hop** | Shows next hop for a given source/destination | Verify routing is correct |
| **Connection Troubleshoot** | End-to-end connectivity check | Test full path connectivity |
| **Effective Routes** | Shows actual route table on a NIC | Debug routing issues |
| **Effective NSG** | Shows combined NSG rules on a NIC | Debug security rules |
| **VPN Troubleshoot** | Diagnoses VPN gateway issues | VPN connectivity problems |
| **Packet Capture** | Captures packets on a VM NIC | Deep network analysis |
| **NSG Flow Logs** | Logs traffic through NSGs | Audit and troubleshooting |
| **Connection Monitor** | Continuous connectivity monitoring | Proactive alerting |
| **Traffic Analytics** | Visualizes NSG flow log data | Network usage insights |

### Connection Monitor — Deep Dive

Connection Monitor is the primary continuous monitoring tool for Azure network connectivity. It provides unified, continuous network connectivity monitoring between Azure VMs, on-premises hosts, and external endpoints.

#### Architecture
- **Source endpoints**: Azure VMs or on-premises hosts with Network Watcher Agent extension (Azure) or Azure Arc agent + Azure Monitor Agent (on-prem)
- **Destination endpoints**: Azure VMs, on-prem hosts, URLs, FQDNs, IP addresses (no extension required on destinations)
- **Test configurations**: Define protocol (TCP, ICMP, HTTP), port, frequency (30-1800s), and thresholds
- **Test groups**: Combine sources, destinations, and test configurations into logical groups
- **Outputs**: Metrics to Azure Monitor, logs to Log Analytics workspace

#### Key Metrics
| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| **ChecksFailedPercent** | Percentage of failed connectivity checks | > 0% for any failure, > 50% for severe |
| **RoundTripTimeMs** | Average round-trip time in milliseconds | Baseline + 2x standard deviation |

#### Connection Monitor for SRE Agent Integration
When a Connection Monitor alert fires, the SRE Agent should investigate by:
1. Identifying which test group failed (source → destination path)
2. Mapping the network path (source VM → NSG → UDR → NVA → UDR → NSG → destination)
3. Checking each hop: effective routes, NSG rules, NVA health, VPN status
4. Correlating with recent Azure Activity Log changes
5. Providing root cause and remediation steps

#### Common Connection Monitor Failure Patterns
| Pattern | Likely Cause | First Check |
|---------|-------------|-------------|
| All tests from one spoke fail | Spoke UDR or peering issue | Effective routes on spoke VM NIC |
| All tests through one hub fail | Hub NVA or LB issue | NVA IP forwarding, LB health probes |
| Cross-hub tests fail | VPN or inter-hub routing | VPN connection status, BGP routes |
| Tests to on-prem fail | VPN tunnel or on-prem routing | VPN status, BGP peer status |
| Single test fails | Specific NSG or iptables rule | IP Flow Verify, NVA firewall rules |
| Intermittent failures | NVA overload or route flapping | NVA CPU/memory, BGP route changes |

#### Diagnostic CLI for Connection Monitor
```bash
# List connection monitors
az network watcher connection-monitor list -l <location>

# Show connection monitor details
az network watcher connection-monitor show -l <location> -n <name>

# Query test results
az network watcher connection-monitor query -l <location> -n <name>

# Start/stop connection monitor
az network watcher connection-monitor start -l <location> -n <name>
az network watcher connection-monitor stop -l <location> -n <name>
```

#### KQL Queries for Connection Monitor
```kusto
// Connection Monitor test results — failed checks
NWConnectionMonitorTestResult
| where TimeGenerated > ago(1h)
| where TestResult == "Fail"
| project TimeGenerated, ConnectionMonitorResourceId, SourceName, DestinationName,
          TestGroupName, TestConfigurationName, TestResult, ChecksFailed, ChecksTotal
| order by TimeGenerated desc

// Connection Monitor path diagnostics
NWConnectionMonitorPathResult
| where TimeGenerated > ago(1h)
| where PathTestResult == "Fail"
| project TimeGenerated, SourceName, DestinationName, HopAddresses, Issues
| order by TimeGenerated desc

// Average RTT by test group over time
NWConnectionMonitorTestResult
| where TimeGenerated > ago(24h)
| summarize AvgRtt=avg(AvgRoundTripTimeMs), MaxRtt=max(MaxRoundTripTimeMs),
            FailedPercent=avg(ChecksFailed * 100.0 / ChecksTotal)
    by bin(TimeGenerated, 5m), TestGroupName
| order by TimeGenerated desc
```

### Common Diagnostic Workflows

#### "VM Can't Reach Destination"
1. **Next Hop** — verify routing is pointing to correct next hop
2. **IP Flow Verify** — check if NSGs allow the traffic
3. **Connection Troubleshoot** — test end-to-end path
4. If through NVA: check NVA effective routes, IP Forwarding, firewall rules

#### "VPN Connectivity Issues"
1. Check VPN connection status (`connectionStatus`)
2. Check BGP peer status (`list-bgp-peer-status`)
3. Check learned/advertised routes
4. Run VPN Troubleshoot for detailed diagnostics
5. Check gateway health metrics in Azure Monitor

#### "Intermittent Connectivity"
1. Enable Connection Monitor for continuous testing
2. Check NSG Flow Logs for denied traffic
3. Check Azure Monitor metrics for packet drops
4. Check NVA health and resource utilization
5. Check for route flapping (BGP route changes)

## Azure Monitor for Networking

### Key Metrics to Monitor

#### VPN Gateway Metrics
| Metric | Alert Threshold | Description |
|--------|----------------|-------------|
| Tunnel Ingress/Egress Bytes | Baseline deviation | Traffic volume through tunnel |
| Tunnel Ingress/Egress Packet Drop | > 0 sustained | Packet loss |
| BGP Peer Status | 0 (down) | BGP session health |
| BGP Routes Advertised/Learned | Sudden change | Route table stability |
| Gateway P2S Connection Count | Sudden drop | P2S connectivity issues |

#### Load Balancer Metrics (for NVA)
| Metric | Alert Threshold | Description |
|--------|----------------|-------------|
| Health Probe Status | < 100% | Backend (NVA) health |
| Data Path Availability | < 100% | LB data path issues |
| SNAT Connection Count | Near limit | Port exhaustion |
| Packet Count | Baseline deviation | Traffic volume |

#### VNet/NSG Metrics
| Metric | Alert Threshold | Description |
|--------|----------------|-------------|
| Bytes In/Out | Baseline deviation | Traffic patterns |
| Packets Dropped (Platform) | > 0 sustained | Platform-level drops |

### Log Analytics Queries (KQL)

```kusto
// VPN tunnel status changes
AzureDiagnostics
| where Category == "TunnelDiagnosticLog"
| where TimeGenerated > ago(24h)
| project TimeGenerated, Resource, status_s, remoteIP_s
| order by TimeGenerated desc

// BGP route changes
AzureDiagnostics
| where Category == "RouteDiagnosticLog"
| where TimeGenerated > ago(24h)
| project TimeGenerated, Resource, prefix_s, nextHop_s, asPath_s
| order by TimeGenerated desc

// NSG flow log analysis - denied traffic
AzureNetworkAnalytics_CL
| where FlowStatus_s == "D"
| where TimeGenerated > ago(1h)
| summarize count() by SrcIP_s, DestIP_s, DestPort_d, NSGRule_s
| order by count_ desc
```

## Troubleshooting Decision Tree

### Step 1: Identify the Scope
- Single VM connectivity → Start with effective routes and NSG
- Spoke-to-spoke → Check NVA path (routes, IP forwarding, firewall rules)
- On-premises connectivity → Check VPN/ExpressRoute first, then NVA path
- Internet connectivity → Check NSG outbound rules, NVA NAT, public IP

### Step 2: Check the Data Plane Path
```
Source VM → Source NSG → Source Routing → [NVA?] → Destination Routing → Destination NSG → Destination VM
```
At each hop, verify:
- Routing points to correct next hop
- NSG allows the traffic
- NVA (if present) allows and forwards the traffic

### Step 3: Check Control Plane
- VPN: Connection status, BGP peer status, IKE/IPsec negotiation
- Peering: Peering state (Connected vs Disconnected), settings
- Route tables: Association to correct subnets
- Gateway: Provisioning state, gateway health

## Common Failure Patterns

### Pattern: Traffic Black-Hole
- **Symptoms**: Packets leave source but never arrive at destination
- **Common causes**:
  - UDR pointing to non-existent or stopped NVA
  - NVA IP Forwarding disabled
  - Incorrect next hop IP in UDR
  - Route table not associated to subnet

### Pattern: Asymmetric Routing
- **Symptoms**: Connection timeouts, intermittent failures
- **Common causes**:
  - Active/active NVA without load balancer
  - Inconsistent UDRs (forward and return paths through different NVAs)
  - Missing GatewaySubnet UDR

### Pattern: NSG Lockout
- **Symptoms**: Sudden loss of connectivity after NSG change
- **Common causes**:
  - Deny rule with higher priority blocking legitimate traffic
  - Removed allow rule for management traffic (SSH/RDP)
  - NSG applied to wrong subnet

### Pattern: VPN Flapping
- **Symptoms**: Tunnel repeatedly going up and down
- **Common causes**:
  - IPsec SA lifetime mismatch
  - DPD (Dead Peer Detection) settings too aggressive
  - Unstable Internet connectivity
  - On-premises device issues
