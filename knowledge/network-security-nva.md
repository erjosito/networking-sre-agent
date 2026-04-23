# Network Security and NVA Operations - SRE Knowledge Base

## Overview

This document covers network security in Azure with focus on Network Virtual Appliances (NVAs), Azure Firewall, NSGs, and their integration in hub-and-spoke topologies.

## Firewall/NVA Integration in Hub-and-Spoke

### Basic Design Pattern
Traffic between spokes and to/from on-premises is routed through a central firewall/NVA in the hub VNet.

### Required Route Tables

#### Spoke Subnet Route Table
- 0.0.0.0/0 → NVA private IP (catches all non-local traffic)
- Gateway route propagation: **DISABLED** (forces all traffic through NVA)

#### GatewaySubnet Route Table
- Each spoke prefix (e.g., 10.11.0.0/16, 10.12.0.0/16) → NVA private IP
- Gateway route propagation: **ENABLED** (required for gateway control plane)
- **Must use exact spoke prefixes**, not summary routes (otherwise system routes from peering take precedence)
- Do NOT add routes for hub VNet prefix, firewall subnet, or gateway subnet

#### NVA Subnet Route Table
- Typically allows BGP route propagation to learn on-premises routes
- May need UDRs for specific traffic steering requirements

### Security Boundaries

- **VNet level** (recommended): Traffic crossing VNet boundaries inspected by firewall; intra-VNet traffic controlled by NSGs
- **Subnet level** (micro-segmentation): Requires overriding local VNet route to point to firewall; significantly increases complexity
- For micro-segmentation: add UDR for local VNet prefix → NVA, PLUS UDR for local subnet prefix → VNet (to keep intra-subnet traffic local)

## NVA (Linux-based) Operations

### IP Forwarding Configuration

#### Azure Level
```bash
# Enable IP forwarding on NIC
az network nic update -g <rg> -n <nic-name> --ip-forwarding true

# Verify IP forwarding status
az network nic show -g <rg> -n <nic-name> --query 'enableIpForwarding'
```

#### OS Level (Linux)
```bash
# Check current setting
sysctl net.ipv4.ip_forward

# Enable temporarily
sudo sysctl -w net.ipv4.ip_forward=1

# Enable permanently
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-ip-forward.conf
sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf
```

### iptables Firewall Configuration

#### Basic NVA Forwarding Rules
```bash
# Allow all forwarding (permissive NVA)
sudo iptables -P FORWARD ACCEPT

# View current rules
sudo iptables -L FORWARD -v -n --line-numbers

# Allow specific traffic (e.g., spoke-to-spoke)
sudo iptables -A FORWARD -s 10.11.0.0/16 -d 10.12.0.0/16 -j ACCEPT
sudo iptables -A FORWARD -s 10.12.0.0/16 -d 10.11.0.0/16 -j ACCEPT

# Block specific traffic
sudo iptables -A FORWARD -s 10.11.0.0/16 -d 10.22.0.0/16 -j DROP

# Allow established/related connections (stateful)
sudo iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Default deny forwarding
sudo iptables -P FORWARD DROP
```

#### NAT/Masquerade for Internet Access
```bash
# Enable masquerade for outbound Internet
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

#### Persist iptables Rules
```bash
# Save rules
sudo iptables-save | sudo tee /etc/iptables/rules.v4

# Restore rules (on boot via iptables-persistent)
sudo apt install iptables-persistent
```

## Network Security Groups (NSGs)

### Best Practices
- Apply NSGs to subnets (not individual NICs) for easier management
- Create explicit deny rules to override permissive default VirtualNetwork tag
- Use Application Security Groups (ASGs) for application-tier rules
- NSGs are stateful — allow rules permit return traffic automatically

### Critical NSG Rules to Verify

| Rule | Direction | Purpose |
|------|-----------|---------|
| Allow Azure Load Balancer | Inbound | Health probes from 168.63.129.16 |
| Allow SSH/RDP from management | Inbound | Administrative access |
| Allow application ports | Inbound | Application-specific traffic |
| Deny all inbound (low priority) | Inbound | Explicit deny-all as catch-all |

### NSG Flow Logs
- Enable for traffic auditing and troubleshooting
- Stored in Azure Storage, queryable via Log Analytics
- Show allowed/denied flows per NSG rule

## Common Security Failures

### NVA Failures
| Failure | Impact | Detection | Resolution |
|---------|--------|-----------|------------|
| IP Forwarding disabled (Azure) | All transit traffic dropped | Check NIC properties | Enable IP Forwarding on NIC |
| IP Forwarding disabled (OS) | All transit traffic dropped | `sysctl net.ipv4.ip_forward` | Set to 1 in sysctl |
| iptables FORWARD DROP | All transit traffic dropped | `iptables -L FORWARD` | Add ACCEPT rules or change policy |
| iptables rules flushed | Traffic may pass unfiltered or blocked | `iptables -L` | Restore rules from backup |
| NVA VM stopped | No transit traffic | Check VM status | Start VM, check LB health |
| NVA NIC detached | No connectivity | Check NIC attachment | Reattach NIC |

### UDR Failures
| Failure | Impact | Detection | Resolution |
|---------|--------|-----------|------------|
| Missing default route in spoke | Traffic bypasses NVA | Check effective routes | Add 0.0.0.0/0 → NVA UDR |
| Wrong next hop IP | Traffic sent to wrong destination | Check effective routes | Correct the next hop IP |
| Route table not associated | UDRs not applied | Check subnet associations | Associate route table to subnet |
| Summary route on GatewaySubnet | System routes take precedence | Check effective routes on GW | Use exact spoke prefixes |
| BGP propagation enabled on spoke | On-prem routes bypass NVA | Check route table settings | Disable propagation |

### NSG Failures
| Failure | Impact | Detection | Resolution |
|---------|--------|-----------|------------|
| Overly restrictive NSG | Legitimate traffic blocked | NSG flow logs, IP flow verify | Add allow rules |
| NSG blocking LB probes | NVA appears unhealthy | LB health probe status | Allow AzureLoadBalancer tag |
| NSG on GatewaySubnet | Gateway malfunction | Gateway diagnostics | Remove NSG from GatewaySubnet |
| Missing return traffic rule | Asymmetric filtering | Connection test | Verify stateful rules or add explicit allow |

## Diagnostic Commands

```bash
# Check NVA forwarding
az network nic show -g <rg> -n <nic> --query 'enableIpForwarding'

# Check effective routes (shows what NIC actually uses)
az network nic show-effective-route-table -g <rg> -n <nic>

# Check effective NSG rules
az network nic list-effective-nsg -g <rg> -n <nic>

# IP Flow Verify (test if specific traffic is allowed)
az network watcher test-ip-flow -g <rg> --vm <vm> --direction <Inbound|Outbound> --protocol <TCP|UDP> --local <ip:port> --remote <ip:port>

# Check NSG flow logs
az network watcher flow-log show -g <rg> -n <nsg-name>

# Check LB health probe status
az network lb probe list -g <rg> --lb-name <lb-name>
```
