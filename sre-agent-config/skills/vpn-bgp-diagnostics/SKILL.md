# VPN and BGP Diagnostics Guide

Use this skill when investigating VPN connectivity or BGP route propagation
issues between the hub VNets and the on-premises simulation VNet.

## Architecture

```
Hub1 (ASN 65001) ←──S2S VPN + BGP──→ OnPrem GW (ASN 65100)
Hub2 (ASN 65002) ←──S2S VPN + BGP──→ OnPrem GW (ASN 65100)
Hub1 ←──S2S VPN + BGP──→ Hub2
```

4 VPN connections total:
- netsre-hub1-to-onprem
- netsre-hub2-to-onprem
- netsre-onprem-to-hub1
- netsre-onprem-to-hub2

## Quick diagnostic commands

```bash
# Check all VPN connection statuses
az network vpn-connection list -g netsre-rg -o table \
  --query "[].{Name:name, Status:connectionStatus, Egress:egressBytesTransferred, Ingress:ingressBytesTransferred}"

# Check a specific VPN connection
az network vpn-connection show -g netsre-rg -n netsre-hub1-to-onprem \
  --query "{status:connectionStatus, sharedKey:sharedKey, enableBgp:enableBgp}" -o json

# Check BGP peer status
az network vnet-gateway list-bgp-peer-status -g netsre-rg -n netsre-hub1-gw -o table

# Check BGP learned routes
az network vnet-gateway list-learned-routes -g netsre-rg -n netsre-hub1-gw -o table

# Check BGP advertised routes
az network vnet-gateway list-advertised-routes -g netsre-rg -n netsre-hub1-gw \
  --peer <bgp-peer-ip> -o table

# Check GatewaySubnet route table
az network route-table show -g netsre-rg -n netsre-hub1-gw-rt \
  --query "routes[].{Name:name, Prefix:addressPrefix, NextHop:nextHopIpAddress}" -o table
```

## Common VPN/BGP issues

### VPN connection not established
- **Symptom**: connectionStatus = "NotConnected" or "Connecting"
- **Causes**:
  - Mismatched shared key → verify both sides use the same key
  - Gateway not provisioned → check gateway provisioningState
  - Network connectivity issue → check gateway public IPs are reachable
- **Fix**: Recreate the connection with correct shared key:
  ```bash
  az network vpn-connection create -g netsre-rg -n netsre-hub1-to-onprem \
    --vnet-gateway1 netsre-hub1-gw --vnet-gateway2 netsre-onprem-gw \
    --shared-key "TestVpnKey2025!" --enable-bgp
  ```

### BGP peers not established
- **Symptom**: BGP peer state = "Unknown" or "Connecting"
- **Causes**:
  - BGP not enabled on the connection → `--enable-bgp` missing
  - ASN mismatch → verify ASN configuration on both gateways
  - GatewaySubnet NSG blocking BGP → port 179 must be allowed
- **Check**: `az network vnet-gateway show -g netsre-rg -n netsre-hub1-gw --query "bgpSettings"`

### Spoke routes not propagated to on-prem
- **Symptom**: On-prem VM cannot reach spoke VMs
- **Causes**:
  - Spoke prefixes not in hub gateway's BGP table
  - BGP propagation disabled on GatewaySubnet route table
  - Missing static routes in GatewaySubnet RT
- **Check**: `az network vnet-gateway list-learned-routes -g netsre-rg -n netsre-onprem-gw`
- **Verify**: Spoke prefixes (10.11.0.0/16, 10.12.0.0/16, 10.21.0.0/16, 10.22.0.0/16) should appear

### On-prem routes not reaching spokes
- **Symptom**: Spoke VMs cannot reach on-prem VM
- **Causes**:
  - BGP propagation enabled on spoke route tables (conflicts with NVA UDR)
  - Missing on-prem route in NVA subnet route table
  - NVA subnet cross-hub routes missing
- **Check**: Spoke RT should have `disableBgpRoutePropagation: true`
- **Check**: NVA subnet RT should have routes for remote hub's spokes

### GatewaySubnet NSG blocking traffic
- **Symptom**: VPN established but no data flows
- **Check**: `az network nsg show -g netsre-rg -n <gw-nsg> --query "securityRules"`
- **Fix**: GatewaySubnet should NOT have restrictive NSGs; remove if present

### Gateway BGP propagation disabled
- **Symptom**: BGP routes not appearing in GatewaySubnet effective routes
- **Check**: `az network route-table show -g netsre-rg -n netsre-hub1-gw-rt --query "disableBgpRoutePropagation"`
- **Expected**: `false` (BGP propagation should be enabled on GatewaySubnet)

## BGP route expectations

### Hub1 gateway should learn:
- 10.100.0.0/16 (on-prem) via on-prem gateway
- 10.2.0.0/16 (hub2) via hub2 gateway or on-prem gateway

### On-prem gateway should learn:
- 10.1.0.0/16 (hub1) via hub1 gateway
- 10.2.0.0/16 (hub2) via hub2 gateway
- Spoke prefixes via hub gateways (if static routes exist in hub GW RTs)

### Route tables (static UDRs):
- Spoke RTs: 0.0.0.0/0 → NVA LB, BGP propagation DISABLED
- GW RTs: spoke prefixes → NVA LB, BGP propagation ENABLED
- NVA RTs: cross-hub routes → remote NVA LB
