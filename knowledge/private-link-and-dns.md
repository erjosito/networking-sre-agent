# Private Link and DNS Resolution in Azure

## Overview

Azure Private Link enables private access to Azure PaaS services (e.g., Storage Accounts, Key Vault, SQL Database) over a private endpoint in your VNet. Traffic stays on the Microsoft backbone and never traverses the public internet.

## Architecture Components

### Private Endpoint
- A network interface with a private IP address from your VNet subnet
- Connected to a specific Azure PaaS resource (sub-resource like `web`, `blob`, `vault`)
- Traffic to the PaaS service resolves to this private IP instead of the public IP

### Private DNS Zone
- Required for name resolution: maps the PaaS service FQDN to the private endpoint IP
- Zone name follows the pattern `privatelink.<service>.azure.net` (e.g., `privatelink.web.core.windows.net` for Storage static websites)
- Must be linked to VNets that need to resolve the private endpoint
- A record is auto-registered via a Private DNS Zone Group on the endpoint

### Private Endpoint Network Policies
- By default, UDRs and NSGs do NOT apply to private endpoint traffic
- Enable `privateEndpointNetworkPolicies` on the subnet to allow UDR/NSG enforcement
- This is critical for routing PE traffic through an NVA (firewall)

## DNS Resolution Flow

### From Azure VNets (spokes) — via Custom DNS
1. Spoke VNet is configured with a custom DNS server pointing to the hub NVA LB IP
2. VM queries DNS for `<account>.z20.web.core.windows.net`
3. Query is sent to NVA (dnsmasq) via the LB
4. dnsmasq forwards to Azure DNS (168.63.129.16)
5. Azure DNS resolves via Private DNS Zone (linked to hub VNet) to private endpoint IP (e.g., `10.1.4.4`)
6. Traffic flows: VM → UDR → NVA → Private Endpoint

**Important**: The Private DNS Zone is linked only to hub VNets (not spokes). Spokes rely on their custom DNS setting pointing to the NVA for proper PE resolution. If a spoke's DNS is reset to Azure default, the spoke has no DNS Zone link and resolves the PE FQDN to the **public IP** instead of the private endpoint IP.

### From On-Premises (via VPN/ExpressRoute)
1. On-prem VM queries DNS for `<account>.z20.web.core.windows.net`
2. DNS request is forwarded to a DNS proxy in Azure (e.g., dnsmasq on NVA)
3. DNS proxy forwards to Azure DNS (168.63.129.16)
4. Azure DNS resolves via Private DNS Zone to private IP
5. Response flows back to on-prem VM
6. Traffic flows: On-prem VM → VPN Gateway → NVA → Private Endpoint

### DNS Proxy (dnsmasq)
- Installed on NVA VMs in the hub
- Configured to forward all queries to Azure DNS (168.63.129.16)
- Both spoke VNets and on-prem VMs use the NVA LB frontend IP as their DNS server
- Azure DNS is only accessible from within Azure VNets, so a proxy is needed for on-prem
- Spoke VNets use custom DNS to route queries through the NVA, which then uses Azure DNS + Private DNS Zones linked to the hub

## Routing Considerations

### Spoke-to-PE Traffic
- Spokes are peered to the hub where the PE resides
- VNet peering system routes (e.g., 10.1.0.0/16) would bypass the NVA
- A more-specific UDR for the PE subnet (e.g., 10.1.4.0/24 → NVA) forces traffic through the NVA
- The PE subnet must have `privateEndpointNetworkPolicies: Enabled`

### Return Traffic (PE to Spoke)
- PE subnet needs a route table with spoke prefixes → NVA
- Without this, return traffic goes directly via peering, causing asymmetric routing

### On-Prem to PE Traffic
- On-prem → VPN Gateway → GatewaySubnet route table → NVA → PE
- GatewaySubnet route table must include route for PE subnet → NVA

## Common Issues and Troubleshooting

### DNS Resolution Failures
- **Symptom**: PaaS FQDN resolves to public IP instead of private IP
- **Cause**: Private DNS Zone not linked to VNet, or DNS zone group not configured
- **Fix**: Verify VNet links on the Private DNS Zone, check A record exists

### dnsmasq Not Running
- **Symptom**: On-prem DNS queries to NVA time out
- **Cause**: systemd-resolved conflict on port 53, or dnsmasq not started
- **Fix**: Disable systemd-resolved, restart dnsmasq

### Traffic Bypassing NVA
- **Symptom**: Spoke can reach PE directly (no NVA logs)
- **Cause**: Missing UDR for PE subnet in spoke route table, or PE network policies not enabled
- **Fix**: Add specific UDR for PE subnet → NVA, enable `privateEndpointNetworkPolicies`

### NSG Blocking PE Traffic
- **Symptom**: Connection to PE times out
- **Cause**: NSG on PE subnet blocking inbound traffic
- **Fix**: Check NSG rules allow traffic from spoke/on-prem ranges on port 443

### Private Endpoint Connection Rejected
- **Symptom**: PE IP unreachable from all sources
- **Cause**: PE connection in Rejected state (not Approved)
- **Fix**: Check PE connection status, re-approve if needed

### Connection Monitor HTTP Probe Failing
- **Symptom**: CM shows spoke-to-staticweb test failures
- **Cause**: DNS misconfiguration (FQDN resolves to public IP), PE connection rejected, or NSG blocking PE subnet
- **Fix**: Verify DNS resolution from the source VM returns the PE private IP, check PE connection is Approved

## Key Azure CLI Commands

```bash
# Check private endpoint status
az network private-endpoint show -g <rg> -n <pe-name> --query "{state:provisioningState, connections:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}"

# Check private DNS zone records
az network private-dns record-set a list -g <rg> -z privatelink.web.core.windows.net

# Check VNet links on DNS zone
az network private-dns link vnet list -g <rg> -z privatelink.web.core.windows.net

# Test DNS resolution from a VM
az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts "nslookup <account>.z20.web.core.windows.net"

# Check dnsmasq status on NVA
az vm run-command invoke -g <rg> -n <nva> --command-id RunShellScript --scripts "systemctl status dnsmasq && dig <account>.z20.web.core.windows.net @127.0.0.1"

# Check effective routes for PE subnet traffic
az network nic show-effective-route-table -g <rg> -n <spoke-vm-nic>

# Test static website HTTP response via PE
az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts "curl -s -o /dev/null -w '%{http_code}' https://<account>.z20.web.core.windows.net/"
```
