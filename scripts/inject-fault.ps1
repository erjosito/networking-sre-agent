<#
.SYNOPSIS
    Fault injection for Azure networking test environment (PowerShell).

.DESCRIPTION
    Injects or reverts specific networking faults in a hub-spoke Azure topology.

.PARAMETER Scenario
    The fault scenario to inject (or revert). See examples below.

.PARAMETER ResourceGroup
    Azure resource group name (default: netsre-rg).

.PARAMETER Prefix
    Resource name prefix (default: netsre).

.PARAMETER Revert
    If specified, reverts the fault instead of injecting it.

.PARAMETER VpnSharedKey
    Shared key for VPN connection recreation (default: FaultTestSharedKey123!).

.EXAMPLE
    .\inject-fault.ps1 -Scenario ip-forwarding-hub1
    .\inject-fault.ps1 -Scenario ip-forwarding-hub1 -Revert
    .\inject-fault.ps1 -Scenario multi-fault -ResourceGroup myrg -Prefix test
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        "ip-forwarding-hub1", "ip-forwarding-hub2",
        "udr-wrong-nexthop", "udr-missing-route", "udr-detach",
        "nsg-block-icmp", "nsg-block-all", "nsg-block-ssh",
        "nva-iptables-drop", "nva-iptables-block-spoke", "nva-os-forwarding", "nva-stop-ssh", "nva-no-internet",
        "vpn-disconnect", "bgp-propagation", "gw-disable-bgp-propagation", "gateway-nsg",
        "peering-disconnect", "peering-no-gateway-transit", "peering-no-use-remote-gw",
        "multi-fault"
    )]
    [string]$Scenario,

    [Alias("g")]
    [string]$ResourceGroup = "netsre-rg",

    [string]$Prefix = "netsre",
    [switch]$Revert,
    [string]$VpnSharedKey = "FaultTestSharedKey123!"
)

$ErrorActionPreference = "Stop"

# ─── Derived resource names ─────────────────────────────────────────────────
# Must match Bicep naming conventions exactly
$Hub1NvaNic       = "$Prefix-hub1-nva-nic"
$Hub2NvaNic       = "$Prefix-hub2-nva-nic"
$Hub1NvaVm        = "$Prefix-hub1-nva"
$Hub2NvaVm        = "$Prefix-hub2-nva"
$Spoke11Rt        = "$Prefix-spoke11-rt"
$Spoke11Vnet      = "$Prefix-spoke11-vnet"
$Spoke11Nsg       = "$Prefix-spoke11-nsg"
$Hub1Vnet         = "$Prefix-hub1-vnet"
$Hub1GwRt         = "$Prefix-hub1-gw-rt"
$Hub1VpnConn      = "$Prefix-conn-hub1-to-onprem"
$Hub1ToSpoke11    = "$Hub1Vnet-to-spoke11"
$Spoke11ToHub1    = "spoke11-to-$Hub1Vnet"
$Hub1NvaLb        = "$Prefix-hub1-nva-lb"
$Hub1NvaLbFe      = "nva-frontend"
$OnpremVnet       = "$Prefix-onprem-vnet"
$DefaultRouteName = "default-to-nva"

# ─── Helpers ─────────────────────────────────────────────────────────────────
function Write-Info    { param([string]$Msg) Write-Host "[INFO]   $Msg" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Msg) Write-Host "[OK]     $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "[WARN]   $Msg" -ForegroundColor Yellow }
function Write-Err     { param([string]$Msg) Write-Host "[ERROR]  $Msg" -ForegroundColor Red }
function Write-Impact  { param([string]$Msg) Write-Host "[IMPACT] $Msg" -ForegroundColor Yellow }

function Get-LbFrontendIp {
    try {
        $ip = az network lb frontend-ip show -g $ResourceGroup --lb-name $Hub1NvaLb -n $Hub1NvaLbFe --query "privateIPAddress" -o tsv 2>$null
        if ($ip) { return $ip }
    } catch {}
    return "10.1.0.100"
}

function Invoke-AzSafe {
    param([string[]]$Arguments)
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Command returned non-zero exit code (idempotent, continuing)"
    }
}

# ─── Scenario functions ─────────────────────────────────────────────────────

function Invoke-IpForwardingHub1 {
    if ($Revert) {
        Write-Info "Re-enabling IP forwarding on $Hub1NvaNic"
        az network nic update -g $ResourceGroup -n $Hub1NvaNic --ip-forwarding true -o none
        Write-Ok "IP forwarding re-enabled on Hub1 NVA NIC"
    } else {
        Write-Info "Disabling IP forwarding on $Hub1NvaNic"
        Write-Info "REASON: Without IP forwarding the NVA NIC drops transit traffic at the Azure fabric level."
        az network nic update -g $ResourceGroup -n $Hub1NvaNic --ip-forwarding false -o none
        Write-Ok "IP forwarding disabled on Hub1 NVA NIC"
        Write-Impact "All traffic routed through Hub1 NVA will be black-holed."
        Write-Impact "Connection Monitors: spoke11<->spoke12, spoke11<->spoke21, spoke11<->onprem will FAIL."
    }
}

function Invoke-IpForwardingHub2 {
    if ($Revert) {
        Write-Info "Re-enabling IP forwarding on $Hub2NvaNic"
        az network nic update -g $ResourceGroup -n $Hub2NvaNic --ip-forwarding true -o none
        Write-Ok "IP forwarding re-enabled on Hub2 NVA NIC"
    } else {
        Write-Info "Disabling IP forwarding on $Hub2NvaNic"
        Write-Info "REASON: Without IP forwarding the NVA NIC drops transit traffic at the Azure fabric level."
        az network nic update -g $ResourceGroup -n $Hub2NvaNic --ip-forwarding false -o none
        Write-Ok "IP forwarding disabled on Hub2 NVA NIC"
        Write-Impact "All traffic routed through Hub2 NVA will be black-holed."
        Write-Impact "Connection Monitors: spoke21<->spoke22, spoke21<->spoke11, spoke22<->onprem will FAIL."
    }
}

function Invoke-UdrWrongNexthop {
    $routeName = "default-to-nva"
    if ($Revert) {
        $correctIp = Get-LbFrontendIp
        Write-Info "Restoring spoke11 UDR default route to correct next hop ($correctIp)"
        az network route-table route update -g $ResourceGroup --route-table-name $Spoke11Rt -n $routeName `
            --next-hop-type VirtualAppliance --next-hop-ip-address $correctIp --address-prefix "0.0.0.0/0" -o none
        Write-Ok "Spoke11 default route restored to $correctIp"
    } else {
        $wrongIp = "10.255.255.1"
        Write-Info "Changing spoke11 UDR default-to-nva next hop to unreachable IP ($wrongIp)"
        Write-Info "REASON: Traffic is sent to a non-existent appliance; packets are dropped."
        az network route-table route update -g $ResourceGroup --route-table-name $Spoke11Rt -n $routeName `
            --next-hop-type VirtualAppliance --next-hop-ip-address $wrongIp --address-prefix "0.0.0.0/0" -o none
        Write-Ok "Spoke11 default-to-nva next hop changed to $wrongIp"
        Write-Impact "All outbound traffic from spoke11 will be black-holed."
        Write-Impact "Connection Monitors: spoke11->any destination will FAIL."
    }
}

function Invoke-UdrMissingRoute {
    $routeName = "default-to-nva"
    if ($Revert) {
        $correctIp = Get-LbFrontendIp
        Write-Info "Re-creating default route in spoke11 route table"
        try {
            az network route-table route create -g $ResourceGroup --route-table-name $Spoke11Rt -n $routeName `
                --next-hop-type VirtualAppliance --next-hop-ip-address $correctIp --address-prefix "0.0.0.0/0" -o none 2>$null
        } catch {
            az network route-table route update -g $ResourceGroup --route-table-name $Spoke11Rt -n $routeName `
                --next-hop-type VirtualAppliance --next-hop-ip-address $correctIp --address-prefix "0.0.0.0/0" -o none
        }
        Write-Ok "Default route restored in spoke11 route table"
    } else {
        Write-Info "Deleting default route from spoke11 route table ($Spoke11Rt)"
        Write-Info "REASON: Without a default route, spoke11 traffic uses Azure default routing and bypasses the NVA."
        Invoke-AzSafe @("network", "route-table", "route", "delete", "-g", $ResourceGroup, "--route-table-name", $Spoke11Rt, "-n", $routeName, "-o", "none")
        Write-Ok "Default route removed from spoke11 route table"
        Write-Impact "Spoke11 traffic bypasses the NVA firewall. Cross-hub and on-prem traffic may fail."
        Write-Impact "Connection Monitors: spoke11<->spoke21, spoke11<->onprem may FAIL."
    }
}

function Invoke-UdrDetach {
    $subnetName = "default"
    if ($Revert) {
        Write-Info "Re-attaching route table $Spoke11Rt to spoke11 default subnet"
        az network vnet subnet update -g $ResourceGroup --vnet-name $Spoke11Vnet -n $subnetName `
            --route-table $Spoke11Rt -o none
        Write-Ok "Route table re-attached to spoke11/default subnet"
    } else {
        Write-Info "Detaching route table from spoke11 default subnet"
        Write-Info "REASON: Without a route table the subnet uses only Azure system routes; NVA routing is lost."
        az network vnet subnet update -g $ResourceGroup --vnet-name $Spoke11Vnet -n $subnetName `
            --route-table "" -o none
        Write-Ok "Route table detached from spoke11/default subnet"
        Write-Impact "Spoke11 workload VM loses all custom routing."
        Write-Impact "Connection Monitors: all spoke11 paths will revert to system routes; cross-hub & on-prem FAIL."
    }
}

function Invoke-NsgBlockIcmp {
    $ruleName = "FaultInject-Block-ICMP"
    if ($Revert) {
        Write-Info "Removing ICMP-blocking NSG rule from $Spoke11Nsg"
        Invoke-AzSafe @("network", "nsg", "rule", "delete", "-g", $ResourceGroup, "--nsg-name", $Spoke11Nsg, "-n", $ruleName, "-o", "none")
        Write-Ok "ICMP-blocking rule removed"
    } else {
        Write-Info "Adding NSG rule to block ICMP on $Spoke11Nsg"
        Write-Info "REASON: Blocks ping/traceroute, simulating a misconfigured NSG."
        az network nsg rule create -g $ResourceGroup --nsg-name $Spoke11Nsg -n $ruleName `
            --priority 100 --direction Inbound --access Deny --protocol Icmp `
            --source-address-prefixes '*' --destination-address-prefixes '*' `
            --source-port-ranges '*' --destination-port-ranges '*' -o none
        Write-Ok "ICMP-blocking rule added to $Spoke11Nsg"
        Write-Impact "Ping-based Connection Monitors targeting spoke11 VMs will FAIL."
    }
}

function Invoke-NsgBlockAll {
    $ruleIn = "FaultInject-Block-All-Inbound"
    $ruleOut = "FaultInject-Block-All-Outbound"
    if ($Revert) {
        Write-Info "Removing all-traffic-blocking NSG rules from $Spoke11Nsg"
        Invoke-AzSafe @("network", "nsg", "rule", "delete", "-g", $ResourceGroup, "--nsg-name", $Spoke11Nsg, "-n", $ruleIn, "-o", "none")
        Invoke-AzSafe @("network", "nsg", "rule", "delete", "-g", $ResourceGroup, "--nsg-name", $Spoke11Nsg, "-n", $ruleOut, "-o", "none")
        Write-Ok "Blocking rules removed"
    } else {
        Write-Info "Adding NSG rules to block ALL traffic on $Spoke11Nsg"
        Write-Info "REASON: Simulates total network isolation of the spoke11 subnet."
        az network nsg rule create -g $ResourceGroup --nsg-name $Spoke11Nsg -n $ruleIn `
            --priority 100 --direction Inbound --access Deny --protocol '*' `
            --source-address-prefixes '*' --destination-address-prefixes '*' `
            --source-port-ranges '*' --destination-port-ranges '*' -o none
        az network nsg rule create -g $ResourceGroup --nsg-name $Spoke11Nsg -n $ruleOut `
            --priority 100 --direction Outbound --access Deny --protocol '*' `
            --source-address-prefixes '*' --destination-address-prefixes '*' `
            --source-port-ranges '*' --destination-port-ranges '*' -o none
        Write-Ok "All-traffic-blocking rules added to $Spoke11Nsg"
        Write-Impact "Spoke11 is completely isolated - no inbound or outbound traffic."
        Write-Impact "Connection Monitors: ALL spoke11 paths will FAIL."
    }
}

function Invoke-NsgBlockSsh {
    $ruleName = "FaultInject-Block-SSH"
    if ($Revert) {
        Write-Info "Removing SSH-blocking NSG rule from $Spoke11Nsg"
        Invoke-AzSafe @("network", "nsg", "rule", "delete", "-g", $ResourceGroup, "--nsg-name", $Spoke11Nsg, "-n", $ruleName, "-o", "none")
        Write-Ok "SSH-blocking rule removed"
    } else {
        Write-Info "Adding NSG rule to block SSH on $Spoke11Nsg"
        Write-Info "REASON: Simulates a misconfigured NSG that blocks management access."
        az network nsg rule create -g $ResourceGroup --nsg-name $Spoke11Nsg -n $ruleName `
            --priority 100 --direction Inbound --access Deny --protocol Tcp `
            --source-address-prefixes '*' --destination-address-prefixes '*' `
            --source-port-ranges '*' --destination-port-ranges '22' -o none
        Write-Ok "SSH-blocking rule added to $Spoke11Nsg"
        Write-Impact "SSH connections to spoke11 VMs will FAIL."
    }
}

function Invoke-NvaIptablesDrop {
    if ($Revert) {
        Write-Info "Restoring iptables FORWARD policy to ACCEPT on $Hub1NvaVm"
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript --scripts "iptables -P FORWARD ACCEPT" -o none
        Write-Ok "iptables FORWARD policy set to ACCEPT on Hub1 NVA"
    } else {
        Write-Info "Setting iptables FORWARD policy to DROP on $Hub1NvaVm"
        Write-Info "REASON: The NVA OS silently drops all forwarded packets."
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript --scripts "iptables -P FORWARD DROP" -o none
        Write-Ok "iptables FORWARD policy set to DROP on Hub1 NVA"
        Write-Impact "Hub1 NVA drops all transit traffic at the OS level."
        Write-Impact "Connection Monitors: spoke11<->spoke12, spoke11<->spoke21, spoke11<->onprem will FAIL."
    }
}

function Invoke-NvaIptablesBlockSpoke {
    $spoke11Prefix = "10.11.0.0/16"
    if ($Revert) {
        Write-Info "Removing iptables rule blocking spoke11 traffic on $Hub1NvaVm"
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript `
            --scripts "iptables -D FORWARD -s $spoke11Prefix -j DROP 2>/dev/null; iptables -D FORWARD -d $spoke11Prefix -j DROP 2>/dev/null; echo done" -o none
        Write-Ok "iptables spoke11 block rules removed on Hub1 NVA"
    } else {
        Write-Info "Adding iptables rules blocking spoke11 ($spoke11Prefix) traffic on $Hub1NvaVm"
        Write-Info "REASON: NVA selectively drops traffic to/from spoke11, simulating a firewall misconfiguration."
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript `
            --scripts "iptables -C FORWARD -s $spoke11Prefix -j DROP 2>/dev/null || iptables -I FORWARD 1 -s $spoke11Prefix -j DROP; iptables -C FORWARD -d $spoke11Prefix -j DROP 2>/dev/null || iptables -I FORWARD 1 -d $spoke11Prefix -j DROP" -o none
        Write-Ok "iptables spoke11 block rules added on Hub1 NVA"
        Write-Impact "Spoke11 traffic through Hub1 NVA will be dropped."
    }
}

function Invoke-NvaOsForwarding {
    if ($Revert) {
        Write-Info "Re-enabling OS-level IP forwarding (sysctl) on $Hub1NvaVm"
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript `
            --scripts "sysctl -w net.ipv4.ip_forward=1; sed -i 's/^net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' /etc/sysctl.conf" -o none
        Write-Ok "OS-level IP forwarding re-enabled on Hub1 NVA"
    } else {
        Write-Info "Disabling OS-level IP forwarding (sysctl) on $Hub1NvaVm"
        Write-Info "REASON: Even with Azure NIC IP forwarding enabled, the Linux kernel must also forward packets."
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript --scripts "sysctl -w net.ipv4.ip_forward=0" -o none
        Write-Ok "OS-level IP forwarding disabled on Hub1 NVA"
        Write-Impact "Hub1 NVA will not forward packets despite Azure NIC forwarding being on."
        Write-Impact "Connection Monitors: all paths through Hub1 NVA will FAIL."
    }
}

function Invoke-NvaStopSsh {
    if ($Revert) {
        Write-Info "Re-starting SSH daemon on both NVA VMs"
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript `
            --scripts "systemctl start sshd || systemctl start ssh" -o none
        az vm run-command invoke -g $ResourceGroup -n $Hub2NvaVm `
            --command-id RunShellScript `
            --scripts "systemctl start sshd || systemctl start ssh" -o none
        Write-Ok "SSH daemon re-started on both NVAs"
    } else {
        Write-Info "Stopping SSH daemon on both NVA VMs ($Hub1NvaVm, $Hub2NvaVm)"
        Write-Info "REASON: The LB health probe uses TCP:22 (SSH). Stopping sshd makes the LB mark both backends as unhealthy."
        az vm run-command invoke -g $ResourceGroup -n $Hub1NvaVm `
            --command-id RunShellScript `
            --scripts "systemctl stop sshd || systemctl stop ssh" -o none
        az vm run-command invoke -g $ResourceGroup -n $Hub2NvaVm `
            --command-id RunShellScript `
            --scripts "systemctl stop sshd || systemctl stop ssh" -o none
        Write-Ok "SSH daemon stopped on both NVAs"
        Write-Impact "LB health probes (TCP:22) will fail on both backends."
        Write-Impact "The LB will have no healthy backends - ALL traffic through the NVA will be black-holed."
        Write-Impact "Connection Monitors: ALL paths through both hubs will FAIL."
    }
}

function Invoke-NvaNoInternet {
    $hub1Vnet = "$Prefix-hub1-vnet"
    $natGwName = "$Prefix-hub1-natgw"
    if ($Revert) {
        Write-Info "Re-associating NAT Gateway $natGwName with Hub1 NvaSubnet"
        az network vnet subnet update -g $ResourceGroup --vnet-name $hub1Vnet -n "NvaSubnet" --nat-gateway $natGwName -o none 2>$null
        Write-Ok "NAT Gateway restored on Hub1 NvaSubnet"
    } else {
        Write-Info "Removing NAT Gateway from Hub1 NvaSubnet"
        Write-Info "REASON: Without NAT Gateway and with defaultOutboundAccess=false, NVAs lose all outbound internet. SNAT for spoke traffic fails."
        az network vnet subnet update -g $ResourceGroup --vnet-name $hub1Vnet -n "NvaSubnet" --remove natGateway -o none 2>$null
        Write-Ok "NAT Gateway removed from Hub1 NvaSubnet"
        Write-Impact "NVAs in Hub1 cannot reach the internet - SNAT for spoke outbound traffic will fail."
        Write-Impact "Connection Monitors: spokes-to-internet test group will FAIL for Hub1 spokes."
    }
}

function Invoke-VpnDisconnect {
    $hub1Gw = "$Prefix-hub1-vpngw"
    $onpremGw = "$Prefix-onprem-vpngw"
    if ($Revert) {
        Write-Info "Re-creating VPN connection $Hub1VpnConn"
        try {
            az network vpn-connection create -g $ResourceGroup -n $Hub1VpnConn `
                --vnet-gateway1 $hub1Gw --vnet-gateway2 $onpremGw `
                --shared-key $VpnSharedKey --enable-bgp -o none 2>$null
        } catch {
            az network vpn-connection create -g $ResourceGroup -n $Hub1VpnConn `
                --vnet-gateway1 $hub1Gw --vnet-gateway2 $onpremGw `
                --shared-key $VpnSharedKey -o none
        }
        Write-Ok "VPN connection $Hub1VpnConn re-created"
        Write-Info "Note: it may take a few minutes for the tunnel to come up."
    } else {
        Write-Info "Deleting VPN connection $Hub1VpnConn"
        Write-Info "REASON: Simulates a VPN tunnel failure between hub1 and on-prem."
        Invoke-AzSafe @("network", "vpn-connection", "delete", "-g", $ResourceGroup, "-n", $Hub1VpnConn, "-o", "none")
        Write-Ok "VPN connection $Hub1VpnConn deleted"
        Write-Impact "On-prem connectivity via Hub1 is lost."
        Write-Impact "Connection Monitors: spoke11<->onprem, spoke12<->onprem will FAIL."
    }
}

function Invoke-BgpPropagation {
    if ($Revert) {
        Write-Info "Disabling BGP route propagation on $Spoke11Rt (restoring UDR-only routing)"
        az network route-table update -g $ResourceGroup -n $Spoke11Rt --disable-bgp-route-propagation true -o none
        Write-Ok "BGP propagation disabled on spoke11 route table"
    } else {
        Write-Info "Enabling BGP route propagation on $Spoke11Rt"
        Write-Info "REASON: BGP-learned routes may override UDRs, causing traffic to bypass the NVA."
        az network route-table update -g $ResourceGroup -n $Spoke11Rt --disable-bgp-route-propagation false -o none
        Write-Ok "BGP propagation enabled on spoke11 route table"
        Write-Impact "Spoke11 may learn routes directly from VPN gateway, bypassing the NVA."
    }
}

function Invoke-GwDisableBgpPropagation {
    if ($Revert) {
        Write-Info "Re-enabling BGP route propagation on $Hub1GwRt (restoring normal gateway routing)"
        az network route-table update -g $ResourceGroup -n $Hub1GwRt --disable-bgp-route-propagation false -o none
        Write-Ok "BGP propagation re-enabled on Hub1 GatewaySubnet route table"
    } else {
        Write-Info "Disabling BGP route propagation on $Hub1GwRt"
        Write-Info "REASON: Without BGP-learned routes the GatewaySubnet loses return paths to spoke and on-prem prefixes."
        az network route-table update -g $ResourceGroup -n $Hub1GwRt --disable-bgp-route-propagation true -o none
        Write-Ok "BGP propagation disabled on Hub1 GatewaySubnet route table"
        Write-Impact "The VPN gateway will not learn BGP routes from peers; return traffic to on-prem prefixes will be dropped."
        Write-Impact "Connection Monitors: spoke11<->onprem, spoke12<->onprem will FAIL."
    }
}

function Invoke-GatewayNsg {
    $gwNsg = "$Prefix-fault-gw-nsg"
    $gwSubnet = "GatewaySubnet"
    if ($Revert) {
        Write-Info "Removing NSG from Hub1 GatewaySubnet"
        az network vnet subnet update -g $ResourceGroup --vnet-name $Hub1Vnet -n $gwSubnet --network-security-group "" -o none 2>$null
        Invoke-AzSafe @("network", "nsg", "delete", "-g", $ResourceGroup, "-n", $gwNsg, "-o", "none")
        Write-Ok "NSG removed from Hub1 GatewaySubnet"
    } else {
        Write-Info "Creating restrictive NSG and applying to Hub1 GatewaySubnet"
        Write-Info "REASON: NSGs on GatewaySubnet can break VPN/ExpressRoute gateway operation."
        az network nsg create -g $ResourceGroup -n $gwNsg -o none 2>$null
        az network nsg rule create -g $ResourceGroup --nsg-name $gwNsg -n "DenyAll" `
            --priority 100 --direction Inbound --access Deny --protocol '*' `
            --source-address-prefixes '*' --destination-address-prefixes '*' `
            --source-port-ranges '*' --destination-port-ranges '*' -o none 2>$null
        az network vnet subnet update -g $ResourceGroup --vnet-name $Hub1Vnet -n $gwSubnet `
            --network-security-group $gwNsg -o none
        Write-Ok "Restrictive NSG applied to Hub1 GatewaySubnet"
        Write-Impact "VPN gateway control plane & data plane traffic will be blocked."
        Write-Impact "Connection Monitors: all on-prem paths through Hub1 will FAIL."
    }
}

function Invoke-PeeringDisconnect {
    if ($Revert) {
        Write-Info "Re-creating VNet peering between hub1 and spoke11"
        $hub1Id = az network vnet show -g $ResourceGroup -n $Hub1Vnet --query id -o tsv
        $spoke11Id = az network vnet show -g $ResourceGroup -n $Spoke11Vnet --query id -o tsv
        az network vnet peering create -g $ResourceGroup --vnet-name $Hub1Vnet -n $Hub1ToSpoke11 `
            --remote-vnet $spoke11Id --allow-vnet-access --allow-forwarded-traffic `
            --allow-gateway-transit -o none 2>$null
        az network vnet peering create -g $ResourceGroup --vnet-name $Spoke11Vnet -n $Spoke11ToHub1 `
            --remote-vnet $hub1Id --allow-vnet-access --allow-forwarded-traffic `
            --use-remote-gateways -o none 2>$null
        Write-Ok "VNet peering between hub1 and spoke11 restored"
    } else {
        Write-Info "Deleting VNet peering between hub1 and spoke11"
        Write-Info "REASON: Without peering, spoke11 is completely disconnected from hub1."
        Invoke-AzSafe @("network", "vnet", "peering", "delete", "-g", $ResourceGroup, "--vnet-name", $Hub1Vnet, "-n", $Hub1ToSpoke11, "-o", "none")
        Invoke-AzSafe @("network", "vnet", "peering", "delete", "-g", $ResourceGroup, "--vnet-name", $Spoke11Vnet, "-n", $Spoke11ToHub1, "-o", "none")
        Write-Ok "VNet peering between hub1 and spoke11 deleted"
        Write-Impact "Spoke11 is completely disconnected from hub1 and the rest of the network."
        Write-Impact "Connection Monitors: ALL spoke11 paths will FAIL."
    }
}

function Invoke-PeeringNoGatewayTransit {
    if ($Revert) {
        Write-Info "Re-enabling AllowGatewayTransit on hub1->spoke11 peering"
        az network vnet peering update -g $ResourceGroup --vnet-name $Hub1Vnet -n $Hub1ToSpoke11 `
            --set allowGatewayTransit=true -o none
        Write-Ok "AllowGatewayTransit restored on hub1->spoke11 peering"
    } else {
        Write-Info "Disabling AllowGatewayTransit on hub1->spoke11 peering"
        Write-Info "REASON: Without AllowGatewayTransit the hub VPN gateway routes are not shared with spoke11."
        az network vnet peering update -g $ResourceGroup --vnet-name $Hub1Vnet -n $Hub1ToSpoke11 `
            --set allowGatewayTransit=false -o none
        Write-Ok "AllowGatewayTransit disabled on hub1->spoke11 peering"
        Write-Impact "Spoke11 can no longer use the hub1 VPN gateway for on-prem connectivity."
        Write-Impact "Connection Monitors: spoke11<->onprem will FAIL."
    }
}

function Invoke-PeeringNoUseRemoteGw {
    if ($Revert) {
        Write-Info "Re-enabling UseRemoteGateways on spoke11->hub1 peering"
        az network vnet peering update -g $ResourceGroup --vnet-name $Spoke11Vnet -n $Spoke11ToHub1 `
            --set useRemoteGateways=true -o none
        Write-Ok "UseRemoteGateways restored on spoke11->hub1 peering"
    } else {
        Write-Info "Disabling UseRemoteGateways on spoke11->hub1 peering"
        Write-Info "REASON: Without UseRemoteGateways the spoke does not learn gateway routes (BGP or static)."
        az network vnet peering update -g $ResourceGroup --vnet-name $Spoke11Vnet -n $Spoke11ToHub1 `
            --set useRemoteGateways=false -o none
        Write-Ok "UseRemoteGateways disabled on spoke11->hub1 peering"
        Write-Impact "Spoke11 loses all routes learned from the hub1 VPN gateway."
        Write-Impact "Connection Monitors: spoke11<->onprem will FAIL."
    }
}

function Invoke-MultiFault {
    $allScenarios = @(
        "ip-forwarding-hub1", "ip-forwarding-hub2",
        "udr-wrong-nexthop", "udr-missing-route", "udr-detach",
        "nsg-block-icmp", "nsg-block-all", "nsg-block-ssh",
        "nva-iptables-drop", "nva-iptables-block-spoke", "nva-os-forwarding", "nva-stop-ssh", "nva-no-internet",
        "vpn-disconnect", "bgp-propagation", "gw-disable-bgp-propagation", "gateway-nsg",
        "peering-disconnect", "peering-no-gateway-transit", "peering-no-use-remote-gw"
    )
    if ($Revert) {
        Write-Info "Reverting ALL known faults (multi-fault revert)"
        foreach ($s in $allScenarios) {
            try { Invoke-Scenario -Name $s -IsRevert $true } catch { Write-Warn "Revert of $s encountered an issue, continuing..." }
        }
        Write-Ok "All faults reverted"
    } else {
        $count = Get-Random -Minimum 2 -Maximum 4
        $selected = $allScenarios | Get-Random -Count $count
        Write-Info "Injecting $count random faults simultaneously"
        foreach ($s in $selected) {
            Write-Host ""
            Write-Info "--- Injecting fault: $s ---"
            Invoke-Scenario -Name $s -IsRevert $false
        }
        Write-Host ""
        Write-Ok "Multi-fault injection complete ($count faults injected)"
    }
}

# ─── Dispatcher ──────────────────────────────────────────────────────────────
function Invoke-Scenario {
    param([string]$Name, [bool]$IsRevert = $false)
    # Temporarily override Revert for multi-fault recursive calls
    $origRevert = $script:Revert
    $script:Revert = $IsRevert
    try {
        switch ($Name) {
            "ip-forwarding-hub1"       { Invoke-IpForwardingHub1 }
            "ip-forwarding-hub2"       { Invoke-IpForwardingHub2 }
            "udr-wrong-nexthop"        { Invoke-UdrWrongNexthop }
            "udr-missing-route"        { Invoke-UdrMissingRoute }
            "udr-detach"               { Invoke-UdrDetach }
            "nsg-block-icmp"           { Invoke-NsgBlockIcmp }
            "nsg-block-all"            { Invoke-NsgBlockAll }
            "nsg-block-ssh"            { Invoke-NsgBlockSsh }
            "nva-iptables-drop"        { Invoke-NvaIptablesDrop }
            "nva-iptables-block-spoke" { Invoke-NvaIptablesBlockSpoke }
            "nva-os-forwarding"        { Invoke-NvaOsForwarding }
            "nva-stop-ssh"             { Invoke-NvaStopSsh }
            "nva-no-internet"          { Invoke-NvaNoInternet }
            "vpn-disconnect"           { Invoke-VpnDisconnect }
            "bgp-propagation"          { Invoke-BgpPropagation }
            "gw-disable-bgp-propagation" { Invoke-GwDisableBgpPropagation }
            "gateway-nsg"              { Invoke-GatewayNsg }
            "peering-disconnect"       { Invoke-PeeringDisconnect }
            "peering-no-gateway-transit" { Invoke-PeeringNoGatewayTransit }
            "peering-no-use-remote-gw" { Invoke-PeeringNoUseRemoteGw }
            "multi-fault"              { Invoke-MultiFault }
        }
    } finally {
        $script:Revert = $origRevert
    }
}

# ─── Main ────────────────────────────────────────────────────────────────────
Write-Host ""
if ($Revert) {
    Write-Info "=== REVERTING FAULT: $Scenario ==="
} else {
    Write-Warn "=== INJECTING FAULT: $Scenario ==="
}
Write-Info "Resource Group: $ResourceGroup"
Write-Info "Prefix:         $Prefix"
Write-Host ""

Invoke-Scenario -Name $Scenario -IsRevert ([bool]$Revert)

Write-Host ""
Write-Info "Done."
