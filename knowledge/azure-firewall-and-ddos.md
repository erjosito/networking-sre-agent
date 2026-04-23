# Azure Firewall and DDoS Protection - SRE Knowledge Base

## Overview

This document covers Azure Firewall (all SKUs) and Azure DDoS Protection in depth, including architecture, rule processing, policy management, DNS integration, hub-spoke deployment, and DDoS mitigation. Written for SREs who need to troubleshoot, diagnose, and resolve networking issues involving these services.

---

## Azure Firewall Overview

Azure Firewall is a managed, cloud-native, stateful firewall-as-a-service. It provides centralized network and application-level filtering with built-in high availability and unrestricted cloud scalability.

### SKU Comparison

| Feature | Basic | Standard | Premium |
|---|---|---|---|
| Throughput | 250 Mbps | 30 Gbps | 100 Gbps |
| Threat Intelligence | Alert only | Alert & Deny | Alert & Deny |
| IDPS | No | No | Yes (signature-based) |
| TLS Inspection | No | No | Yes |
| URL Filtering | No | FQDN tags only | Full URL path filtering |
| Web Categories | No | Yes | Yes (enhanced) |
| DNS Proxy | No | Yes | Yes |
| Forced Tunneling | No | Yes | Yes |
| Availability Zones | No | Yes | Yes |
| Multiple PIPs | No | Yes (up to 250) | Yes (up to 250) |
| Use Case | Small/dev workloads | Production workloads | High-security / regulated |

### Key Capabilities

- **SNAT**: All outbound traffic is SNATed to the firewall's public IP(s). Azure Firewall uses ports in the range 1024–65535 per PIP. Each PIP provides ~2,496 SNAT ports per backend instance.
- **DNAT**: Inbound traffic can be forwarded (destination NAT) to private IPs behind the firewall.
- **Threat Intelligence**: Can alert on or deny traffic to/from known-malicious IPs and domains. Feed is managed by Microsoft.
- **Forced Tunneling**: Allows routing all internet-bound traffic to an on-premises firewall or NVA. Requires a separate management subnet (`AzureFirewallManagementSubnet`).

---

## Azure Firewall Architecture

### Subnet Requirements

- **AzureFirewallSubnet**: Minimum /26 (recommended /26). Must be named exactly `AzureFirewallSubnet`. This is where the firewall's private IP lives.
- **AzureFirewallManagementSubnet**: Required ONLY for forced tunneling. Minimum /26. Must be named exactly `AzureFirewallManagementSubnet`. Gets its own PIP for management traffic that bypasses the forced tunnel.

### Public IP Addresses

- Firewall requires at least one PIP (Standard SKU, static allocation).
- Additional PIPs increase SNAT capacity (each PIP adds ~2,496 ports per instance).
- DNAT rules can target specific PIPs when multiple are configured.

### Availability Zones

- Standard and Premium can be deployed across availability zones (1, 2, 3).
- Zone selection is made at deployment time and **cannot be changed** after creation.
- Cross-zone deployment provides 99.99% SLA (vs 99.95% single zone).
- No additional cost for zone deployment, but cross-zone data transfer charges apply.

### Internal Architecture

- Azure Firewall runs on multiple backend instances (auto-scaled by Azure).
- Each instance is a dedicated VM with its own SNAT port pool.
- A Standard Load Balancer fronts the backend instances for the private IP.
- A Public Load Balancer fronts the backend instances for each PIP.

---

## Rule Processing

### Rule Types (in processing order)

1. **NAT Rules (DNAT)**: Processed first. Translate inbound connections to private IPs. If a DNAT rule matches, an implicit corresponding network rule is added to allow the translated traffic.
2. **Network Rules**: Processed second. Allow/deny based on source IP, destination IP, port, and protocol (TCP, UDP, ICMP, Any).
3. **Application Rules**: Processed last. Allow/deny based on FQDNs, FQDN tags, URL paths (Premium), and web categories. Operate at L7 (HTTP/HTTPS/MSSQL).

### Rule Collection Groups

- Rule collections are organized into Rule Collection Groups (RCGs).
- RCGs have a priority (100–65000, lower number = higher priority).
- Within an RCG, rule collections also have priorities.
- **Processing order**: RCG priority → Rule collection type (NAT → Network → Application) → Rule collection priority.

### Priority and Match Behavior

- Rules are processed in priority order (lowest number first).
- **First match wins** — once a rule matches, no further rules are evaluated.
- If no rule matches, the **implicit deny** rule blocks the traffic.
- Network rules are evaluated BEFORE application rules (even if the application rule has a higher priority number within the same RCG).

### Important Processing Details

- If a network rule matches any traffic, application rules are NOT evaluated for that traffic.
- To use application rules (FQDN-based filtering) for HTTP/S traffic, ensure no network rule matches the same traffic on ports 80/443.
- FQDN tags (e.g., `WindowsUpdate`, `AzureBackup`) are predefined collections of FQDNs managed by Microsoft.
- ICMP is only supported in network rules, not application rules.

### Example: Common Rule Structure

```
Rule Collection Group: "Platform-RCG" (priority 100)
  ├── NAT Collection: "Inbound-DNAT" (priority 100)
  │   └── Rule: Allow HTTPS inbound → web server
  ├── Network Collection: "Allow-Infra" (priority 200)
  │   └── Rule: Allow DNS (UDP/53) to DNS servers
  └── Application Collection: "Allow-Web" (priority 300)
      └── Rule: Allow *.microsoft.com on HTTPS

Rule Collection Group: "Workload-RCG" (priority 200)
  ├── Network Collection: "Allow-DB" (priority 100)
  │   └── Rule: Allow SQL (TCP/1433) from app subnet
  └── Application Collection: "Allow-APIs" (priority 200)
      └── Rule: Allow api.example.com on HTTPS
```

---

## Firewall Policy

### Overview

Firewall Policy is the recommended way to configure Azure Firewall (replacing classic rules). Policies can be attached to one or more firewalls across regions.

### Hierarchical Policies (Parent/Child)

- A **parent policy** defines base rules (e.g., enterprise-wide security baselines).
- **Child policies** inherit all rules from the parent and can add their own.
- Parent rules **always** take precedence — child policies cannot override them.
- Useful for enterprise governance: central security team owns parent policy, workload teams own child policies.
- Parent rules are processed first (lower effective priority), then child rules.

### Rule Collection Groups in Policy

- Each policy contains rule collection groups (same structure as above).
- RCG priority range: 100–65000.
- Parent policy RCGs are evaluated before child policy RCGs.

### Threat Intelligence Mode

- **Off**: No threat intelligence filtering.
- **Alert only**: Logs alerts for traffic to/from known-malicious IPs/domains.
- **Alert and deny**: Logs and blocks malicious traffic.
- Threat intelligence is evaluated BEFORE any user-defined rules.
- Allowlist can be configured to exempt specific IPs/FQDNs from threat intel filtering.

### IDPS (Premium Only)

- Intrusion Detection and Prevention System with signature-based detection.
- Modes: **Alert** (detect only) or **Alert and Deny** (detect and block).
- Uses Microsoft-managed signature rules (updated automatically).
- Private IP ranges can be configured to define internal network ranges for IDPS.
- Signature rules can be individually overridden (e.g., disable a noisy signature or change action).
- Bypass rules can be created for specific traffic patterns to avoid false positives.

### TLS Inspection (Premium Only)

- Decrypts outbound HTTPS traffic, inspects it with IDPS/application rules, then re-encrypts.
- Requires an **Intermediate CA certificate** stored in Azure Key Vault.
- The firewall generates on-the-fly certificates for inspected connections.
- Clients must trust the CA certificate (deploy via GPO, MDM, or manual install).
- Certain categories (health, finance) can be excluded from TLS inspection.
- **Does NOT inspect** traffic with certificate pinning or mutual TLS (mTLS).

### URL Filtering (Premium Only)

- Filter on full URL paths, not just FQDNs (e.g., block `example.com/malware` but allow `example.com/app`).
- Works on HTTP (full URL visible) and HTTPS (requires TLS inspection to see path).
- Without TLS inspection, HTTPS URL filtering only works on the SNI (effectively FQDN filtering).

---

## DNS Configuration

### DNS Proxy

- When enabled, the firewall acts as a DNS proxy for client VMs.
- Clients point their DNS to the firewall's private IP.
- Firewall forwards DNS queries to the configured DNS server(s).
- **Required for FQDN filtering in network rules** — without DNS proxy, FQDN in network rules does not work.

### Custom DNS Servers

- By default, Azure Firewall uses Azure DNS (168.63.129.16).
- Custom DNS servers can be configured (e.g., on-premises DNS, Azure Private DNS Resolver).
- If custom DNS is set, the firewall forwards queries to those servers.

### FQDN Resolution in Network Rules

- Network rules support FQDN as destination (e.g., `sql-server.database.windows.net`).
- The firewall resolves the FQDN to IP addresses and creates network rules for those IPs.
- DNS resolution is performed by the firewall itself (using its DNS config).
- **DNS proxy must be enabled** for FQDN in network rules to work correctly.
- Resolved IPs are cached based on TTL — short TTLs may cause brief blocking when IPs change.

### DNS Configuration Best Practice

```bash
# Configure custom DNS on the firewall
az network firewall update \
  --name <fw-name> \
  --resource-group <rg> \
  --dns-servers 10.0.0.4 10.0.0.5 \
  --enable-dns-proxy true
```

- Set VNet DNS to firewall private IP so all VMs use the firewall as DNS proxy.
- Firewall forwards to your custom DNS servers.
- This ensures FQDN-based rules resolve correctly.

---

## Firewall in Hub-Spoke Topology

### Standard Deployment Pattern

```
On-premises ←→ [VPN/ER Gateway] ←→ Hub VNet ←→ [Firewall] ←→ Spoke VNets
                                        │
                                   [Internet]
```

### UDR Configuration

#### Spoke Subnets

```bash
# Route all traffic through the firewall
az network route-table route create \
  --route-table-name spoke-rt \
  --resource-group <rg> \
  --name to-firewall \
  --address-prefix 0.0.0.0/0 \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address <firewall-private-ip>
```

- Default route (0.0.0.0/0) → Firewall private IP.
- **Disable BGP route propagation** on spoke route tables (prevents gateway-learned routes from bypassing the firewall).

#### GatewaySubnet

- Add UDRs for each spoke prefix → Firewall private IP.
- **Enable BGP route propagation** (required for gateway operation).
- This ensures on-premises → spoke traffic flows through the firewall.

#### AzureFirewallSubnet

- Typically NO UDRs needed (unless forced tunneling).
- BGP route propagation: enabled (so the firewall learns on-premises routes).
- **Never** add a 0.0.0.0/0 UDR pointing to the firewall itself (routing loop).

### Spoke-to-Spoke Traffic

- With default route (0.0.0.0/0) → Firewall on both spokes, all inter-spoke traffic transits the firewall.
- Firewall must have network or application rules to allow the traffic.
- Source/destination IPs in rules are the original spoke IPs (pre-SNAT).
- Azure Firewall does NOT SNAT private-to-private traffic (RFC 1918 to RFC 1918).

### Internet Egress via Firewall

- Spoke default route (0.0.0.0/0) → Firewall handles internet-bound traffic.
- Firewall SNATs to its public IP(s).
- Application rules can enforce FQDN/URL-based filtering for outbound web access.

### Forced Tunneling to On-Premises

- All internet traffic from the firewall is sent to an on-premises device instead of directly to the internet.
- Requires `AzureFirewallManagementSubnet` with a separate PIP for management traffic.
- The management PIP ensures Azure can still manage the firewall even when the default route is overridden.
- Configure a 0.0.0.0/0 UDR on `AzureFirewallSubnet` → VPN/ER gateway or NVA.

---

## Azure Firewall Manager

### Overview

Azure Firewall Manager provides centralized security policy and route management for cloud-based security perimeters.

### Secured Virtual Hub (vWAN)

- Deploy Azure Firewall inside an Azure Virtual WAN hub.
- Firewall Manager automates route configuration — no manual UDRs needed.
- Supports security partner providers (e.g., Zscaler, iBoss, Check Point) for SaaS-based filtering.
- Can configure both Azure Firewall (for private traffic) and a security partner provider (for internet traffic) in the same hub.

### Hub VNet (Traditional)

- Firewall Manager can also manage policies for firewalls deployed in traditional hub VNets.
- Manual UDR configuration is still required in this model.
- Provides centralized policy management across multiple firewalls/regions.

### Security Partner Providers

- Third-party SECaaS providers integrated via Firewall Manager.
- Route internet traffic to the partner provider for advanced URL/category filtering.
- Azure Firewall handles private traffic; partner handles internet traffic.

---

## DDoS Protection

### Protection Tiers

| Feature | DDoS Network Protection | DDoS IP Protection |
|---|---|---|
| Scope | VNet-level (all PIPs in the VNet) | Individual PIP |
| Pricing | ~$2,944/month + overage | ~$199/month per PIP |
| DDoS Rapid Response (DRR) | Yes | No |
| Cost Protection (credit) | Yes | No |
| WAF discount | Yes | No |
| Metrics & Alerts | Full telemetry | Basic telemetry |
| Mitigation Reports | Yes | Yes |
| Mitigation Flow Logs | Yes | Yes |
| Custom mitigation policies | Via DRR team | No |

### How DDoS Protection Works

- Always-on traffic monitoring analyzes traffic patterns against baselines.
- When an attack is detected, mitigation is automatically triggered.
- Mitigation scrubs malicious traffic at the Azure network edge — clean traffic is forwarded to the resource.
- Mitigation profiles are auto-tuned to the application's traffic pattern.
- Protection applies to layer 3 (network) and layer 4 (transport) attacks.

### Protected Resource Types

- DDoS protection covers any resource with a Public IP:
  - Azure Load Balancer (public)
  - Application Gateway / WAF
  - Azure Firewall
  - VPN Gateway
  - Virtual Machines with PIPs
  - Bastion (indirectly)

### DDoS Protection Plans

- A DDoS Protection Plan can protect up to 100 PIPs across multiple VNets and subscriptions (within the same tenant).
- Plan is linked to VNets — all PIPs in linked VNets are protected.
- One plan per tenant is typically sufficient (single plan can span subscriptions).

### Common Attack Types Mitigated

- **Volumetric attacks**: UDP floods, amplification attacks (DNS, NTP, SSDP).
- **Protocol attacks**: SYN floods, fragmented packet attacks, Ping of Death.
- **Application layer**: L7 attacks require WAF — DDoS Protection covers L3/L4 only.

---

## Common Failure Scenarios

### 1. Firewall Blocking Legitimate Traffic

**Symptoms**: Applications fail to connect; timeouts from spoke VMs.

**Root Causes**:
- Missing allow rule for the traffic (implicit deny).
- Rule priority misconfigured — a deny rule or less specific allow rule matches first.
- Network rule on port 80/443 consuming traffic before application rule can match.
- Wrong source/destination in rules (using NAT'd addresses instead of original IPs).

**Diagnosis**:
```kql
// Check denied traffic in firewall logs
AzureFirewallNetworkRule
| where TimeGenerated > ago(1h)
| where Action == "Deny"
| where SourceIP == "<client-ip>"
| project TimeGenerated, SourceIP, DestinationIP, DestinationPort, Protocol, Action

AzureFirewallApplicationRule
| where TimeGenerated > ago(1h)
| where Action == "Deny"
| where SourceIP == "<client-ip>"
| project TimeGenerated, SourceIP, Fqdn, TargetUrl, Action
```

**Resolution**: Add or fix allow rules. Check rule priority order. Ensure network rules aren't consuming traffic meant for application rules.

### 2. SNAT Port Exhaustion

**Symptoms**: Intermittent outbound connection failures; connections time out to internet destinations.

**Root Causes**:
- High volume of outbound connections to a single destination.
- Too few PIPs for the connection rate.
- Connections not being reused (short-lived TCP connections at high rate).

**Diagnosis**:
```kql
// Check SNAT port utilization metric
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "SNATPortUtilization"
| where TimeGenerated > ago(1h)
| summarize MaxUtilization = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

**Resolution**:
- Add more PIPs to the firewall (each PIP adds ~2,496 ports per instance).
- Use NAT Gateway on the `AzureFirewallSubnet` for greater SNAT capacity (up to 64K ports per IP, up to 16 IPs).
- Investigate whether applications can use connection pooling.

### 3. Asymmetric Routing

**Symptoms**: Connections establish but immediately reset; stateful firewall drops return traffic.

**Root Causes**:
- Return traffic bypasses the firewall (takes a different path than the forward traffic).
- Missing or incorrect UDR on GatewaySubnet.
- BGP route propagation not disabled on spoke route tables.
- Multiple firewalls/NVAs without session affinity.

**Diagnosis**:
```bash
# Check effective routes on a spoke VM NIC
az network nic show-effective-route-table \
  --resource-group <rg> \
  --name <nic-name> \
  --output table

# Check effective routes on GatewaySubnet NIC
az network vnet-gateway list-learned-routes \
  --resource-group <rg> \
  --name <gw-name> \
  --output table
```

**Resolution**:
- Ensure UDRs on GatewaySubnet point spoke prefixes to the firewall.
- Disable BGP route propagation on spoke route tables.
- Verify that all paths (forward and return) traverse the same firewall instance.

### 4. DNS Resolution Failures (DNS Proxy Enabled)

**Symptoms**: VMs cannot resolve DNS names; intermittent DNS timeouts; FQDN-based rules stop working.

**Root Causes**:
- DNS proxy enabled but upstream DNS server unreachable from firewall.
- Firewall DNS configuration pointing to incorrect DNS server IPs.
- DNS proxy overwhelmed (high query rate).
- Circular DNS dependency (VNet DNS set to firewall, but firewall DNS set to a VM in the same VNet that also uses the firewall as DNS).

**Diagnosis**:
```kql
AzureFirewallDnsProxy
| where TimeGenerated > ago(1h)
| where Error != ""
| summarize count() by Error, DnsServer
| order by count_ desc
```

**Resolution**:
- Verify upstream DNS servers are reachable from the firewall.
- Check firewall DNS settings: `az network firewall show --name <fw> -g <rg> --query 'dnsSettings'`.
- Avoid circular DNS dependencies — use IP addresses for firewall DNS config, not FQDNs.

### 5. IDPS False Positives (Premium)

**Symptoms**: Legitimate application traffic is blocked; specific API calls fail intermittently.

**Root Causes**:
- IDPS signature matching legitimate traffic patterns.
- Signature set updated with new rules that match application behavior.

**Diagnosis**:
```kql
AzureFirewallNetworkRule
| where TimeGenerated > ago(24h)
| where Action contains "IDPS"
| project TimeGenerated, SourceIP, DestinationIP, DestinationPort, 
          Action, SignatureId = extract("SignatureId: (\\d+)", 1, msg_s)
| summarize count() by SignatureId, DestinationIP, DestinationPort
| order by count_ desc
```

**Resolution**:
- Identify the triggering signature ID.
- Create a bypass rule for the specific traffic flow, or change the signature action from Deny to Alert.
- In Firewall Policy → IDPS → Signature Rules, override the specific signature.

### 6. TLS Inspection Certificate Issues (Premium)

**Symptoms**: HTTPS connections fail with certificate errors; clients see "untrusted certificate" warnings.

**Root Causes**:
- Intermediate CA certificate not trusted by clients.
- Certificate expired or near expiration in Key Vault.
- Key Vault access issue — firewall cannot retrieve the certificate.
- Client applications using certificate pinning.

**Resolution**:
- Deploy the CA certificate to all clients via GPO, Intune, or configuration management.
- Check certificate expiry in Key Vault and renew if needed.
- Verify firewall's managed identity has Get/List permissions on Key Vault secrets and certificates.
- Exclude certificate-pinned applications from TLS inspection.

### 7. Forced Tunneling Misconfigured

**Symptoms**: Firewall deployment fails; firewall loses management connectivity; cannot update rules.

**Root Causes**:
- `AzureFirewallManagementSubnet` not created.
- Management subnet missing its own PIP.
- UDR on management subnet blocking management traffic.

**Resolution**:
- Create `AzureFirewallManagementSubnet` (/26 minimum) in the hub VNet.
- Assign a separate PIP to the management subnet.
- **Never** apply UDRs to `AzureFirewallManagementSubnet`.
- Ensure NSGs (if any) on the management subnet allow Azure management traffic.

### 8. Firewall Throughput Limits

**Symptoms**: Packet loss; increased latency through the firewall; TCP retransmissions.

**Root Causes**:
- Traffic exceeds SKU throughput limits (Basic: 250 Mbps, Standard: 30 Gbps, Premium: 100 Gbps).
- IDPS or TLS inspection reducing effective throughput (Premium).
- Single large flow exceeding per-flow throughput (single TCP flow limited to ~6-8 Gbps).

**Diagnosis**:
```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "Throughput"
| where TimeGenerated > ago(6h)
| summarize MaxThroughputBps = max(Maximum) by bin(TimeGenerated, 5m)
| extend MaxThroughputGbps = MaxThroughputBps / 1000000000.0
| order by TimeGenerated desc
```

**Resolution**:
- Upgrade SKU if consistently hitting limits.
- Review IDPS/TLS inspection scope — exclude high-bandwidth trusted flows.
- Consider multiple firewall instances for very high throughput requirements.

### 9. DNAT Rules Not Working

**Symptoms**: Inbound connections to the firewall's PIP don't reach the backend server.

**Root Causes**:
- Missing network rule for the translated traffic (DNAT creates implicit allow, but verify).
- Backend server's NSG blocking the traffic (source IP is the original client IP, NOT the firewall IP, because Azure Firewall preserves the source IP for DNAT by default).
- Backend server's return traffic not routing back through the firewall (asymmetric routing).
- DNAT rule targeting wrong PIP (when multiple PIPs are configured).

**Resolution**:
- Verify a corresponding network rule exists allowing traffic from any source to the backend IP/port.
- Update backend NSG to allow the original source IPs (or use service tags / broad ranges for internet-facing services).
- Ensure the backend server's default route points to the firewall (UDR 0.0.0.0/0 → firewall).

### 10. DDoS Mitigation False Positives

**Symptoms**: Legitimate traffic dropped during DDoS mitigation; users experience intermittent connectivity.

**Root Causes**:
- DDoS Protection baseline not yet calibrated (requires ~30 days of learning).
- Sudden legitimate traffic spike (flash sale, product launch) resembles an attack pattern.
- Application traffic pattern closely resembles an attack signature.

**Diagnosis**:
```kql
// Check DDoS mitigation events
AzureDiagnostics
| where Category == "DDoSMitigationFlowLogs"
| where TimeGenerated > ago(1h)
| where msg_s contains "Dropped"
| project TimeGenerated, SourceIP = sourceAddress_s, 
          DestinationIP = destinationAddress_s, Protocol = protocol_s
| summarize DroppedCount = count() by SourceIP, bin(TimeGenerated, 5m)
| order by DroppedCount desc
```

**Resolution**:
- If you have DDoS Network Protection, engage **DDoS Rapid Response (DRR)** team during active incidents.
- Pre-notify Microsoft before expected traffic spikes (via DRR).
- Review and adjust mitigation policies (tuning available via DRR engagement).

### 11. DDoS Attack Overwhelming Application Tier

**Symptoms**: Application unresponsive despite DDoS network protection being active; L7 attack patterns.

**Root Causes**:
- Application-layer (L7) attack — HTTP floods, slow POST, etc.
- DDoS Protection only covers L3/L4; L7 attacks pass through network-level mitigation.
- Application not scaled to handle the connection rate.

**Resolution**:
- Deploy **Azure WAF** (with Application Gateway or Front Door) for L7 DDoS protection.
- Enable WAF bot protection rules.
- Implement rate limiting at the application layer.
- Use Azure Front Door for global load balancing and DDoS absorption at the edge.
- Scale out application tier (auto-scale rules).

---

## Troubleshooting

### Firewall Log Categories

| Log Category | Content |
|---|---|
| `AzureFirewallApplicationRule` | Application rule hits (allow/deny), FQDN, URL, web categories |
| `AzureFirewallNetworkRule` | Network rule hits (allow/deny), source/dest IP, port, protocol, IDPS events |
| `AzureFirewallDnsProxy` | DNS proxy queries, upstream responses, errors |
| `AzureFirewallThreatIntel` | Threat intelligence hits |
| `AzureFirewallFatFlow` | Top flows consuming high bandwidth |
| `AzureFirewallFlowTrace` | Flow-level connection tracking (verbose — use sparingly) |

### Enable Diagnostic Logging

```bash
# Enable all firewall log categories to Log Analytics
az monitor diagnostic-settings create \
  --name fw-diagnostics \
  --resource <firewall-resource-id> \
  --workspace <log-analytics-workspace-id> \
  --logs '[
    {"category": "AzureFirewallApplicationRule", "enabled": true},
    {"category": "AzureFirewallNetworkRule", "enabled": true},
    {"category": "AzureFirewallDnsProxy", "enabled": true},
    {"category": "AzureFirewallThreatIntel", "enabled": true}
  ]' \
  --metrics '[{"category": "AllMetrics", "enabled": true}]'
```

### Essential KQL Queries

#### All Denied Traffic (Last Hour)

```kql
union AzureFirewallNetworkRule, AzureFirewallApplicationRule
| where TimeGenerated > ago(1h)
| where Action == "Deny"
| project TimeGenerated, SourceIP, DestinationIP, DestinationPort, 
          Protocol, Fqdn, Action, Policy, RuleCollectionGroup, RuleCollection, Rule
| order by TimeGenerated desc
```

#### Top Blocked Sources

```kql
union AzureFirewallNetworkRule, AzureFirewallApplicationRule
| where TimeGenerated > ago(24h)
| where Action == "Deny"
| summarize BlockedCount = count() by SourceIP
| order by BlockedCount desc
| take 20
```

#### DNS Proxy Failures

```kql
AzureFirewallDnsProxy
| where TimeGenerated > ago(1h)
| where ResponseCode != "NOERROR" and ResponseCode != ""
| summarize FailureCount = count() by QueryName, ResponseCode, DnsServer
| order by FailureCount desc
```

#### Threat Intelligence Hits

```kql
AzureFirewallThreatIntel
| where TimeGenerated > ago(24h)
| project TimeGenerated, SourceIP, DestinationIP, DestinationPort, 
          ThreatDescription, Protocol, Action
| order by TimeGenerated desc
```

#### SNAT Port Utilization Over Time

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "SNATPortUtilization"
| where TimeGenerated > ago(24h)
| summarize AvgUtilization = avg(Average), MaxUtilization = max(Maximum) 
  by bin(TimeGenerated, 15m)
| order by TimeGenerated desc
```

#### Firewall Health State

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "FirewallHealth"
| where TimeGenerated > ago(24h)
| summarize MinHealth = min(Minimum), AvgHealth = avg(Average) 
  by bin(TimeGenerated, 5m)
| where MinHealth < 100
| order by TimeGenerated desc
```

### Key Firewall Metrics

| Metric | Description | Alert Threshold |
|---|---|---|
| `FirewallHealth` | Overall firewall health (%) | < 100% |
| `Throughput` | Data throughput in bits/sec | Approaching SKU limit |
| `SNATPortUtilization` | SNAT port usage (%) | > 70% |
| `DataProcessed` | Total data processed | Billing tracking |
| `ApplicationRuleHit` | Application rule match count | Anomaly detection |
| `NetworkRuleHit` | Network rule match count | Anomaly detection |

### DDoS Telemetry

#### Check if Under DDoS Attack

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "IfUnderDDoSAttack"
| where TimeGenerated > ago(24h)
| where Maximum == 1
| project TimeGenerated, PublicIP = Resource
| order by TimeGenerated desc
```

#### DDoS Packets Dropped vs Forwarded

```kql
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName in ("PacketsDroppedDDoS", "PacketsForwardedDDoS")
| where TimeGenerated > ago(6h)
| summarize Total = sum(Total) by MetricName, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

#### DDoS Mitigation Reports

- **Mitigation reports** are generated automatically during and after an attack.
- Access via: Azure Portal → PIP resource → DDoS Protection → Mitigation Reports.
- Reports include: attack vectors, traffic volume, packets dropped/forwarded, mitigation duration.
- **Mitigation flow logs** provide per-flow detail (source IPs, ports, protocols).

---

## Best Practices

### Rule Organization

- Use a clear naming convention: `<Environment>-<Direction>-<Purpose>` (e.g., `Prod-Outbound-WebAccess`).
- Group rules by function using Rule Collection Groups: Platform (100-199), Shared (200-399), Workload (400+).
- Put the most frequently matched rules at higher priority (lower number) for performance.
- Use **IP Groups** to manage large sets of IPs — reusable across multiple rules.
- Regularly audit rules: remove unused rules, consolidate overlapping rules.

### SNAT Port Management

- Monitor `SNATPortUtilization` metric — alert at 70%.
- Add PIPs proactively before hitting limits (each PIP adds ~2,496 ports per backend instance).
- For high-SNAT workloads, associate a **NAT Gateway** to `AzureFirewallSubnet` (provides up to 64K ports per PIP, up to 16 PIPs = ~1M ports).
- Use connection pooling in applications to reduce SNAT port consumption.

### IP Groups

```bash
# Create an IP Group for spoke address spaces
az network ip-group create \
  --name spoke-addresses \
  --resource-group <rg> \
  --location <location> \
  --ip-addresses 10.1.0.0/16 10.2.0.0/16 10.3.0.0/16
```

- Centrally manage IP address lists used across multiple rules.
- Maximum 200 IP Groups per firewall, 5,000 individual IPs/prefixes per IP Group.
- Changes to an IP Group automatically update all rules referencing it.

### Performance Tuning

- Minimize the number of rules — consolidate where possible.
- Use IP Groups instead of listing IPs inline in rules.
- Application rules (FQDN-based) are more resource-intensive than network rules (IP-based).
- For Premium: scope TLS inspection and IDPS to only the traffic that requires it.
- Use FQDN tags for Azure service traffic — avoids maintaining large IP lists.

### High Availability

- Always deploy across **availability zones** (Standard/Premium) for 99.99% SLA.
- Use multiple PIPs for SNAT redundancy and capacity.
- Monitor `FirewallHealth` metric and alert on degradation.
- Maintain a tested backup policy that can be applied if the primary policy becomes corrupted.

### DDoS Response Planning

- Enable DDoS Network Protection for all production VNets with public-facing resources.
- Configure DDoS alerts on the `IfUnderDDoSAttack` metric.
- If using DDoS Network Protection, register for **DDoS Rapid Response (DRR)** — provides 24/7 access to DDoS experts during active attacks.
- Document a DDoS response runbook:
  1. Confirm attack via metrics and alerts.
  2. Engage DRR if available.
  3. Scale out application tier if L7 impact.
  4. Deploy/tune WAF rules for L7 mitigation.
  5. Review mitigation reports post-attack.
- Use **Azure Front Door** or **CDN** in front of public-facing apps to absorb volumetric attacks at the edge.
- Pre-provision extra capacity in auto-scale rules for DDoS scenarios.

### Logging and Monitoring

- Enable **all** diagnostic log categories to Log Analytics.
- Create dashboards for: denied traffic trends, SNAT utilization, throughput, health state.
- Set up alerts for:
  - `FirewallHealth` < 100% for 5+ minutes.
  - `SNATPortUtilization` > 70%.
  - `Throughput` approaching SKU limit.
  - `IfUnderDDoSAttack` == 1 (DDoS).
  - High rate of denied traffic (possible misconfiguration or reconnaissance).
- Retain firewall logs for at least 90 days for security investigations.
- Use **Workbooks** for visual firewall traffic analysis (Microsoft provides built-in templates).
