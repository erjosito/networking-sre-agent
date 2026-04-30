# Private Endpoint and DNS Diagnostics Guide

Use this skill when investigating Private Endpoint connectivity or DNS
resolution issues for the Storage Account static website accessed via PE.

## Architecture

```
Spoke VM → Custom DNS (NVA LB) → dnsmasq → Azure DNS (168.63.129.16)
                                                     ↓
                                     Private DNS Zone (linked to hub VNets)
                                     privatelink.web.core.windows.net
                                                     ↓
                                          A record → PE IP (10.1.4.x)

Traffic: Spoke VM → UDR → NVA LB → NVA → PE subnet (10.1.4.0/24) → Storage Account
```

- PE name: netsre-hub1-web-pe
- PE subnet: 10.1.4.0/24 (PrivateEndpointSubnet in hub1)
- DNS zone: privatelink.web.core.windows.net
- DNS zone linked to: hub1-vnet, hub2-vnet (NOT spokes or on-prem)
- Spoke DNS servers: NVA LB IPs (hub1 spokes → 10.1.1.200, hub2 spokes → 10.2.1.200)
- On-prem DNS servers: both NVA LBs (10.1.1.200, 10.2.1.200)
- PE subnet has `privateEndpointNetworkPolicies: Enabled` (UDR/NSG apply to PE traffic)

## Quick diagnostic commands

```bash
# Check PE connection status
az network private-endpoint show -g netsre-rg -n netsre-hub1-web-pe \
  --query "{status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status, provisioningState:provisioningState}" -o json

# Get PE private IP from NIC
PE_NIC_ID=$(az network private-endpoint show -g netsre-rg -n netsre-hub1-web-pe \
  --query "networkInterfaces[0].id" -o tsv)
az network nic show --ids $PE_NIC_ID --query "ipConfigurations[0].privateIPAddress" -o tsv

# Check DNS zone records
az network private-dns record-set a list -g netsre-rg \
  -z privatelink.web.core.windows.net -o table

# Check DNS zone VNet links
az network private-dns link vnet list -g netsre-rg \
  -z privatelink.web.core.windows.net -o table

# Check VNet custom DNS settings
az network vnet show -g netsre-rg -n netsre-spoke11-vnet \
  --query "dhcpOptions.dnsServers" -o json

# Test DNS resolution from a VM
az vm run-command invoke -g netsre-rg -n netsre-spoke11-vm \
  --command-id RunShellScript \
  --scripts "nslookup <storage-account>.z20.web.core.windows.net"

# Test HTTP connectivity to static website from a VM
az vm run-command invoke -g netsre-rg -n netsre-spoke11-vm \
  --command-id RunShellScript \
  --scripts "curl -s -o /dev/null -w '%{http_code}' https://<storage-account>.z20.web.core.windows.net/"

# Check dnsmasq on NVA
az vm run-command invoke -g netsre-rg -n netsre-hub1-nva \
  --command-id RunShellScript \
  --scripts "systemctl is-active dnsmasq && dig <storage-account>.z20.web.core.windows.net @127.0.0.1 +short"

# Check PE subnet network policies
az network vnet subnet show -g netsre-rg --vnet-name netsre-hub1-vnet \
  -n PrivateEndpointSubnet --query privateEndpointNetworkPolicies -o tsv

# Check spoke route table for PE subnet route
az network route-table show -g netsre-rg -n netsre-spoke11-rt \
  --query "routes[?contains(addressPrefix,'10.1.4')].{Name:name, Prefix:addressPrefix, NextHop:nextHopIpAddress}" -o table
```

## Common PE/DNS issues

### DNS resolves to public IP instead of PE IP
- **Symptom**: nslookup returns a public IP (not 10.1.4.x)
- **Causes**:
  - VNet custom DNS reset to Azure default → spoke bypasses NVA/dnsmasq
  - Private DNS Zone not linked to hub VNet
  - dnsmasq not running on NVA
- **Check VNet DNS**: `az network vnet show -g netsre-rg -n netsre-spoke11-vnet --query "dhcpOptions.dnsServers"`
- **Fix**: Restore custom DNS to NVA LB IP

### PE connection rejected
- **Symptom**: PE IP unreachable from all sources, connection status = "Rejected"
- **Check**: `az network private-endpoint show -g netsre-rg -n netsre-hub1-web-pe --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState"`
- **Fix**: Re-approve the connection:
  ```bash
  PE_CONN_ID=$(az network private-endpoint-connection list \
    --id <storage-account-id> --query "[?contains(groupIds,'web')].id" -o tsv)
  az network private-endpoint-connection approve --id $PE_CONN_ID
  ```

### PE traffic bypassing NVA
- **Symptom**: PE is reachable but NVA logs show no traffic for 10.1.4.x
- **Causes**:
  - Missing UDR for PE subnet in spoke route table
  - PE subnet network policies not enabled
- **Check routes**: `az network nic show-effective-route-table -g netsre-rg -n netsre-spoke11-vm-nic`
- **Fix**: Add PE subnet route → NVA LB in spoke route table

### NSG blocking PE traffic
- **Symptom**: PE IP unreachable, DNS resolves correctly to PE IP
- **Check**: `az network nsg rule list -g netsre-rg --nsg-name netsre-hub1-pe-nsg -o table`
- **Fix**: Remove or modify deny rules blocking traffic to 10.1.4.0/24

### dnsmasq stopped on NVA
- **Symptom**: DNS queries to NVA timeout, on-prem cannot resolve PE FQDN
- **Check**: `az vm run-command invoke -g netsre-rg -n netsre-hub1-nva --command-id RunShellScript --scripts "systemctl status dnsmasq"`
- **Fix**: `systemctl start dnsmasq && systemctl enable dnsmasq`
- **Root cause**: systemd-resolved may have restarted and reclaimed port 53

### Connection Monitor HTTP probe failing
- **Symptom**: spoke-to-staticweb test group shows failures
- **Investigation order**:
  1. Test DNS resolution from source VM → should return PE IP
  2. Test curl to static website FQDN → should return HTTP 200
  3. Check PE connection status → should be "Approved"
  4. Check NVA health → must be forwarding traffic
  5. Check UDR for PE subnet → must route through NVA
- **Differentiator**: If TCP/ICMP to other destinations works but HTTP to PE fails,
  the issue is DNS or PE-specific, not general routing.

## Expected DNS configuration

| VNet | Custom DNS Servers | Purpose |
|------|--------------------|---------|
| spoke11, spoke12 | 10.1.1.200 | Hub1 NVA LB |
| spoke21, spoke22 | 10.2.1.200 | Hub2 NVA LB |
| on-prem | 10.1.1.200, 10.2.1.200 | Both NVA LBs via VPN |
| hub1, hub2 | Azure default (168.63.129.16) | Direct Azure DNS with zone links |
