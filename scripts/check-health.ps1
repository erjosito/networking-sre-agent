<#
.SYNOPSIS
    Verify the Azure networking test environment is healthy.
.DESCRIPTION
    Checks IP forwarding, peerings, VPN connections, route tables, NSGs,
    NVA OS-level configuration, Application Gateway backend health,
    NVA NAT/SNAT rules, NVA load balancer health probes, and Connection
    Monitor results. Prints a summary: HEALTHY or DEGRADED.
.PARAMETER ResourceGroup
    Resource group name (default: netsre-rg)
.PARAMETER Prefix
    Resource naming prefix (default: netsre)
.PARAMETER Sections
    Comma-separated list of section numbers to run (e.g. 1,4,12).
    If omitted, all sections are run.
.PARAMETER ListSections
    Print the list of available sections and exit.
.EXAMPLE
    .\check-health.ps1
    .\check-health.ps1 -Sections 1,4,12
    .\check-health.ps1 -ListSections
    .\check-health.ps1 -ResourceGroup "my-rg" -Prefix "myprefix" -Sections 8,10
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = "netsre-rg",
    [string]$Prefix = "netsre",
    [int[]]$Sections = @(),
    [switch]$ListSections
)

$ErrorActionPreference = "Continue"

# ─── Section catalog ─────────────────────────────────────────────────────────
$SectionCatalog = [ordered]@{
    1  = "NVA NIC IP Forwarding"
    2  = "VNet Peerings"
    3  = "VPN Connections"
    4  = "Route Table Subnet Associations"
    5  = "UDR Default Route Next Hops"
    6  = "BGP Route Propagation"
    7  = "NSG Blocking Rules"
    8  = "NVA OS Configuration"
    9  = "Application Gateway Backend Health"
    10 = "NVA NAT / SNAT Configuration"
    11 = "NVA Load Balancer Health Probe Status"
    12 = "Connection Monitor Results"
    13 = "NVA Subnet Default Outbound Access"
    14 = "Application Endpoint HTTP Reachability"
    16 = "Spoke VM Local Web Application"
}

if ($ListSections) {
    Write-Host "Available health check sections:" -ForegroundColor Cyan
    foreach ($kv in $SectionCatalog.GetEnumerator()) {
        Write-Host ("  {0,2}. {1}" -f $kv.Key, $kv.Value)
    }
    Write-Host ""
    Write-Host "Usage: .\check-health.ps1 -Sections 1,4,12" -ForegroundColor Gray
    exit 0
}

$runAll = ($Sections.Count -eq 0)
function ShouldRun([int]$n) { return $runAll -or ($Sections -contains $n) }

# ─── Counters ────────────────────────────────────────────────────────────────
$script:PassCount = 0
$script:FailCount = 0
$script:Failures  = @()

function Write-Section($Text) {
    Write-Host ""
    Write-Host "━━━ $Text ━━━" -ForegroundColor Cyan
}

function Write-CheckPass($Text) {
    $script:PassCount++
    Write-Host "[PASS]  $Text" -ForegroundColor Green
}

function Write-CheckFail($Text) {
    $script:FailCount++
    $script:Failures += $Text
    Write-Host "[FAIL]  $Text" -ForegroundColor Red
}

function Write-CheckWarn($Text) {
    Write-Host "[WARN]  $Text" -ForegroundColor Yellow
}

function Write-Info($Text) {
    Write-Host "[INFO]  $Text" -ForegroundColor Cyan
}

# ─── Banner ──────────────────────────────────────────────────────────────────
Write-Info "╔════════════════════════════════════════════════════════════╗"
Write-Info "║  HEALTH CHECK                                             ║"
Write-Info "║  Resource Group: $ResourceGroup"
Write-Info "║  Prefix:         $Prefix"
if (-not $runAll) {
    Write-Info "║  Sections:       $($Sections -join ', ')"
}
Write-Info "╚════════════════════════════════════════════════════════════╝"

###############################################################################
# 1. IP Forwarding on NVA NICs
###############################################################################
if (ShouldRun 1) {
Write-Section "1. NVA NIC IP Forwarding"
foreach ($hub in @("hub1", "hub2")) {
    $nic = "$Prefix-$hub-nva-nic"
    try {
        $fwd = az network nic show -g $ResourceGroup -n $nic --query "enableIPForwarding" -o tsv 2>$null
        if ($fwd -eq "true") {
            Write-CheckPass "$nic`: IP forwarding enabled"
        } else {
            Write-CheckFail "$nic`: IP forwarding is $fwd (expected: true)"
        }
    } catch {
        Write-CheckFail "$nic`: could not query NIC"
    }
}
} # end section 1

###############################################################################
# 2. VNet Peerings
###############################################################################
if (ShouldRun 2) {
Write-Section "2. VNet Peerings"
$peeringPairs = @(
    @{ Hub = "hub1"; Spoke = "spoke11"; PeerName = "$Prefix-hub1-vnet-to-spoke11" },
    @{ Hub = "hub1"; Spoke = "spoke12"; PeerName = "$Prefix-hub1-vnet-to-spoke12" },
    @{ Hub = "hub2"; Spoke = "spoke21"; PeerName = "$Prefix-hub2-vnet-to-spoke21" },
    @{ Hub = "hub2"; Spoke = "spoke22"; PeerName = "$Prefix-hub2-vnet-to-spoke22" },
    @{ Hub = "hub1"; Spoke = "hub2";    PeerName = "$Prefix-hub1-vnet-to-$Prefix-hub2-vnet" },
    @{ Hub = "hub2"; Spoke = "hub1";    PeerName = "$Prefix-hub2-vnet-to-$Prefix-hub1-vnet" }
)
foreach ($pair in $peeringPairs) {
    $vnet = "$Prefix-$($pair.Hub)-vnet"
    try {
        $state = az network vnet peering show -g $ResourceGroup --vnet-name $vnet -n $pair.PeerName --query peeringState -o tsv 2>$null
        if ($state -eq "Connected") {
            Write-CheckPass "Peering $($pair.PeerName): Connected"
        } else {
            Write-CheckFail "Peering $($pair.PeerName): $state (expected: Connected)"
        }
    } catch {
        Write-CheckFail "Peering $($pair.PeerName): MISSING"
    }
}

} # end section 2

###############################################################################
# 3. VPN Connections
###############################################################################
if (ShouldRun 3) {
Write-Section "3. VPN Connections"
$vpnConns = @(
    "$Prefix-conn-hub1-to-onprem",
    "$Prefix-conn-hub2-to-onprem",
    "$Prefix-conn-onprem-to-hub1",
    "$Prefix-conn-onprem-to-hub2"
)
foreach ($conn in $vpnConns) {
    try {
        $status = az network vpn-connection show -g $ResourceGroup -n $conn --query connectionStatus -o tsv 2>$null
        if ($status -eq "Connected") {
            Write-CheckPass "VPN $conn`: Connected"
        } elseif ($status -eq "Connecting") {
            Write-CheckWarn "VPN $conn`: Connecting (may still be initializing)"
            Write-CheckPass "VPN $conn`: $status (acceptable)"
        } elseif ([string]::IsNullOrEmpty($status)) {
            Write-CheckFail "VPN $conn`: MISSING (connection does not exist)"
        } else {
            Write-CheckFail "VPN $conn`: $status (expected: Connected)"
        }
    } catch {
        Write-CheckFail "VPN $conn`: could not query"
    }
}

} # end section 3

###############################################################################
# 4. Route Table Associations
###############################################################################
if (ShouldRun 4) {
Write-Section "4. Route Table Subnet Associations"
$spokeRts = @(
    @{ Spoke = "spoke11"; Subnet = "default"; Rt = "$Prefix-spoke11-rt" },
    @{ Spoke = "spoke12"; Subnet = "default"; Rt = "$Prefix-spoke12-rt" },
    @{ Spoke = "spoke21"; Subnet = "default"; Rt = "$Prefix-spoke21-rt" },
    @{ Spoke = "spoke22"; Subnet = "default"; Rt = "$Prefix-spoke22-rt" }
)
foreach ($entry in $spokeRts) {
    $vnet = "$Prefix-$($entry.Spoke)-vnet"
    try {
        $attachedRt = az network vnet subnet show -g $ResourceGroup --vnet-name $vnet -n $entry.Subnet --query "routeTable.id" -o tsv 2>$null
        if ($attachedRt -and $attachedRt -like "*$($entry.Rt)*") {
            Write-CheckPass "$vnet/$($entry.Subnet): route table $($entry.Rt) attached"
        } elseif ([string]::IsNullOrEmpty($attachedRt)) {
            Write-CheckFail "$vnet/$($entry.Subnet): no route table attached (expected: $($entry.Rt))"
        } else {
            Write-CheckFail "$vnet/$($entry.Subnet): wrong route table attached"
        }
    } catch {
        Write-CheckFail "$vnet/$($entry.Subnet): could not query subnet"
    }
}

# GatewaySubnet route tables (required to force on-prem traffic through NVA)
foreach ($hub in @("hub1", "hub2")) {
    $vnet = "$Prefix-$hub-vnet"
    $expectedRt = "$Prefix-$hub-gw-rt"
    try {
        $attachedRt = az network vnet subnet show -g $ResourceGroup --vnet-name $vnet -n "GatewaySubnet" --query "routeTable.id" -o tsv 2>$null
        if ($attachedRt -and $attachedRt -like "*$expectedRt*") {
            Write-CheckPass "$vnet/GatewaySubnet: route table $expectedRt attached"
        } elseif ([string]::IsNullOrEmpty($attachedRt)) {
            Write-CheckFail "$vnet/GatewaySubnet: no route table — on-prem traffic will bypass the NVA"
        } else {
            Write-CheckWarn "$vnet/GatewaySubnet: unexpected route table attached ($(($attachedRt -split '/')[-1]))"
        }
    } catch {
        Write-CheckFail "$vnet/GatewaySubnet: could not query subnet"
    }

    # Verify the GW RT has BGP propagation ENABLED (the gateway needs BGP routes)
    try {
        $bgpDisabled = az network route-table show -g $ResourceGroup -n $expectedRt --query "disableBgpRoutePropagation" -o tsv 2>$null
        if ($bgpDisabled -eq "true") {
            Write-CheckPass "${expectedRt}: BGP propagation disabled (correct — forces on-prem traffic through NVA via static routes)"
        } else {
            Write-CheckFail "${expectedRt}: BGP propagation enabled — BGP-learned routes will bypass NVA static routes"
        }
    } catch {
        Write-CheckWarn "${expectedRt}: could not query route table"
    }

    # Verify the GW RT contains spoke routes pointing to NVA LB
    try {
        $routesJson = az network route-table route list -g $ResourceGroup --route-table-name $expectedRt -o json 2>$null
        if ($routesJson) {
            $routes = ($routesJson | ConvertFrom-Json)
            $nvaRoutes = $routes | Where-Object { $_.nextHopType -eq "VirtualAppliance" }
            if ($nvaRoutes -and $nvaRoutes.Count -gt 0) {
                Write-CheckPass "${expectedRt}: $($nvaRoutes.Count) route(s) pointing to NVA (VirtualAppliance)"
            } else {
                Write-CheckFail "${expectedRt}: no routes pointing to NVA — on-prem traffic won't be steered through the NVA"
            }
        }
    } catch {
        Write-CheckWarn "${expectedRt}: could not list routes"
    }
}

} # end section 4

###############################################################################
# 5. UDR Default Route Next Hops
###############################################################################
if (ShouldRun 5) {
Write-Section "5. UDR Default Route Next Hops"
foreach ($spoke in @("spoke11", "spoke12", "spoke21", "spoke22")) {
    $rt = "$Prefix-$spoke-rt"
    try {
        $nextHop  = az network route-table route show -g $ResourceGroup --route-table-name $rt -n "default-to-nva" --query "nextHopIpAddress" -o tsv 2>$null
        $nextType = az network route-table route show -g $ResourceGroup --route-table-name $rt -n "default-to-nva" --query "nextHopType" -o tsv 2>$null
        if ($nextType -eq "VirtualAppliance" -and $nextHop -and $nextHop -ne "10.255.255.1") {
            Write-CheckPass "$rt/default-to-nva: next hop $nextHop (VirtualAppliance)"
        } elseif ([string]::IsNullOrEmpty($nextHop)) {
            Write-CheckFail "$rt/default-to-nva: route MISSING"
        } elseif ($nextHop -eq "10.255.255.1") {
            Write-CheckFail "$rt/default-to-nva: next hop is 10.255.255.1 (wrong — fault injected?)"
        } else {
            Write-CheckFail "$rt/default-to-nva: unexpected config (type=$nextType, hop=$nextHop)"
        }
    } catch {
        Write-CheckFail "$rt/default-to-nva: could not query route"
    }
}

} # end section 5

###############################################################################
# 6. BGP Propagation
###############################################################################
if (ShouldRun 6) {
Write-Section "6. BGP Route Propagation (should be disabled on spoke RTs)"
foreach ($spoke in @("spoke11", "spoke12", "spoke21", "spoke22")) {
    $rt = "$Prefix-$spoke-rt"
    try {
        $bgpDisabled = az network route-table show -g $ResourceGroup -n $rt --query "disableBgpRoutePropagation" -o tsv 2>$null
        if ($bgpDisabled -eq "true") {
            Write-CheckPass "$rt`: BGP propagation disabled (correct)"
        } else {
            Write-CheckFail "$rt`: BGP propagation enabled (should be disabled to force NVA routing)"
        }
    } catch {
        Write-CheckFail "$rt`: could not query route table"
    }
}

} # end section 6

###############################################################################
# 7. NSG Fault-Injection Rules
###############################################################################
if (ShouldRun 7) {
Write-Section "7. NSG Blocking Rules (should not exist)"
$faultRules = @("FaultInject-Block-ICMP", "FaultInject-Block-All-Inbound", "FaultInject-Block-All-Outbound", "FaultInject-Block-SSH")
foreach ($spoke in @("spoke11", "spoke12", "spoke21", "spoke22")) {
    $nsg = "$Prefix-$spoke-nsg"
    foreach ($rule in $faultRules) {
        try {
            $exists = az network nsg rule show -g $ResourceGroup --nsg-name $nsg -n $rule --query "name" -o tsv 2>$null
            if ($exists) {
                Write-CheckFail "$nsg`: fault rule $rule still present"
            }
        } catch {
            # Rule doesn't exist — that's good
        }
    }
}
# Check no NSG on GatewaySubnet
try {
    $gwNsg = az network vnet subnet show -g $ResourceGroup --vnet-name "$Prefix-hub1-vnet" -n "GatewaySubnet" --query "networkSecurityGroup.id" -o tsv 2>$null
    if ([string]::IsNullOrEmpty($gwNsg) -or $gwNsg -eq "None") {
        Write-CheckPass "Hub1 GatewaySubnet: no NSG attached (correct)"
    } else {
        Write-CheckFail "Hub1 GatewaySubnet: NSG attached ($gwNsg) — this can break the gateway"
    }
} catch {
    Write-CheckWarn "Hub1 GatewaySubnet: could not check NSG"
}

} # end section 7

###############################################################################
# 8. NVA OS Configuration (via run-command)
###############################################################################
if (ShouldRun 8) {
Write-Section "8. NVA OS Configuration (via run-command)"
foreach ($hub in @("hub1", "hub2")) {
    $vm = "$Prefix-$hub-nva"
    Write-Info "Checking $vm (this may take a moment)..."

    # Check sysctl ip_forward
    try {
        $sysctlOut = az vm run-command invoke -g $ResourceGroup -n $vm `
            --command-id RunShellScript `
            --scripts "sysctl -n net.ipv4.ip_forward" `
            --query "value[0].message" -o tsv 2>$null
        if ($sysctlOut -match "1") {
            Write-CheckPass "$vm`: net.ipv4.ip_forward = 1"
        } else {
            Write-CheckFail "$vm`: net.ipv4.ip_forward != 1 (OS forwarding disabled)"
        }
    } catch {
        Write-CheckWarn "$vm`: could not run sysctl check"
    }

    # Check iptables FORWARD policy
    try {
        $iptablesOut = az vm run-command invoke -g $ResourceGroup -n $vm `
            --command-id RunShellScript `
            --scripts "iptables -L FORWARD -n --line-numbers 2>/dev/null | head -20" `
            --query "value[0].message" -o tsv 2>$null
        if ($iptablesOut -match "policy ACCEPT") {
            Write-CheckPass "$vm`: iptables FORWARD policy is ACCEPT"
        } elseif ($iptablesOut -match "policy DROP") {
            Write-CheckFail "$vm`: iptables FORWARD policy is DROP"
        } else {
            Write-CheckWarn "$vm`: Could not determine iptables FORWARD policy"
        }

        # Check for spoke-blocking rules
        if ($iptablesOut -match "DROP.*10\.11\.0\.0") {
            Write-CheckFail "$vm`: iptables has spoke11-blocking rule"
        }
    } catch {
        Write-CheckWarn "$vm`: could not run iptables check"
    }
}

} # end section 8

###############################################################################
# 9. Application Gateway Backend Health
###############################################################################
if (ShouldRun 9) {
Write-Section "9. Application Gateway Backend Health"
foreach ($hub in @("hub1", "hub2")) {
    $appGw = "$Prefix-$hub-appgw"
    Write-Info "Querying backend health for $appGw (may take 30-60s)..."
    try {
        $healthJson = az network application-gateway show-backend-health `
            -g $ResourceGroup -n $appGw -o json 2>$null
        if ($healthJson) {
            $health = $healthJson | ConvertFrom-Json
            $pools = $health.backendAddressPools
            foreach ($pool in $pools) {
                foreach ($server in $pool.backendHttpSettingsCollection) {
                    foreach ($backend in $server.servers) {
                        $addr  = $backend.address
                        $state = $backend.health
                        if ($state -eq "Healthy") {
                            Write-CheckPass "$appGw backend $addr`: $state"
                        } else {
                            Write-CheckFail "$appGw backend $addr`: $state"
                        }
                    }
                }
            }
        } else {
            Write-CheckWarn "$appGw`: no backend health data returned"
        }
    } catch {
        Write-CheckWarn "$appGw`: could not query backend health — AppGW may not exist"
    }
}

} # end section 9

###############################################################################
# 10. NVA NAT/SNAT Configuration (iptables nat table)
###############################################################################
if (ShouldRun 10) {
Write-Section "10. NVA NAT / SNAT Configuration"
foreach ($hub in @("hub1", "hub2")) {
    $vm = "$Prefix-$hub-nva"
    Write-Info "Checking iptables NAT rules on $vm..."
    try {
        $natOut = az vm run-command invoke -g $ResourceGroup -n $vm `
            --command-id RunShellScript `
            --scripts "iptables -t nat -L POSTROUTING -n -v 2>/dev/null; echo '---'; iptables -t nat -L INTERNET_SNAT -n -v 2>/dev/null" `
            --query "value[0].message" -o tsv 2>$null
        if ($natOut -match "MASQUERADE" -or $natOut -match "SNAT") {
            Write-CheckPass "$vm`: SNAT / MASQUERADE rules found in nat table"
            # Show brief summary
            $natOut -split "`n" | Where-Object { $_ -match "MASQUERADE|SNAT|RETURN|INTERNET_SNAT" } | ForEach-Object {
                Write-Info "  $_"
            }
        } else {
            Write-CheckFail "$vm`: no SNAT/MASQUERADE rules found — outbound internet NAT not configured"
        }
    } catch {
        Write-CheckWarn "$vm`: could not query iptables NAT table"
    }
}

} # end section 10

###############################################################################
# 11. NVA Load Balancer Health Probe Status
###############################################################################
if (ShouldRun 11) {
Write-Section "11. NVA Load Balancer Health Probe Status"
foreach ($hub in @("hub1", "hub2")) {
    $lb = "$Prefix-$hub-nva-lb"
    Write-Info "Querying LB probe status for $lb..."
    try {
        # Get backend pool health via REST (az network lb show doesn't expose probe status directly)
        $backendJson = az network nic show -g $ResourceGroup -n "$Prefix-$hub-nva-nic" `
            --query "ipConfigurations[0].loadBalancerBackendAddressPools[0].id" -o tsv 2>$null
        if ($backendJson) {
            # Check if the LB exists and probe is configured
            $lbJson = az network lb show -g $ResourceGroup -n $lb -o json 2>$null | ConvertFrom-Json
            $probes = $lbJson.probes
            if ($probes -and $probes.Count -gt 0) {
                $probeName = $probes[0].name
                $probePort = $probes[0].port
                $probeProto = $probes[0].protocol
                Write-CheckPass "$lb`: probe configured — $probeName ($probeProto`:$probePort)"
                # Verify NVA is listening on probe port by running command
                $vm = "$Prefix-$hub-nva"
                $listenOut = az vm run-command invoke -g $ResourceGroup -n $vm `
                    --command-id RunShellScript `
                    --scripts "ss -tlnp | grep ':$probePort ' || echo 'NOT_LISTENING'" `
                    --query "value[0].message" -o tsv 2>$null
                if ($listenOut -match "NOT_LISTENING") {
                    Write-CheckFail "$vm`: NOT listening on probe port $probePort — LB will mark backend unhealthy"
                } elseif ($listenOut -match ":$probePort") {
                    Write-CheckPass "$vm`: listening on probe port $probePort"
                } else {
                    Write-CheckWarn "$vm`: could not determine if listening on port $probePort"
                }
            } else {
                Write-CheckFail "$lb`: no health probe configured"
            }
        } else {
            Write-CheckWarn "$lb`: NVA NIC not associated with LB backend pool"
        }
    } catch {
        Write-CheckWarn "$lb`: could not query load balancer"
    }
}

} # end section 11

###############################################################################
# 12. Connection Monitor Results
###############################################################################
if (ShouldRun 12) {
Write-Section "12. Connection Monitor Results"
$cmName = "$Prefix-connection-monitor"
$cmLocation = az group show -n $ResourceGroup --query location -o tsv 2>$null
$nwName = "NetworkWatcher_$cmLocation"
Write-Info "Querying Connection Monitor v2 '$cmName' in NetworkWatcherRG..."
try {
    # Use v2 parameters: --location identifies the Network Watcher region
    $cmJson = az network watcher connection-monitor show `
        --name $cmName `
        --location $cmLocation `
        -o json 2>$null
    if ($cmJson) {
        $cm = $cmJson | ConvertFrom-Json
        Write-Info "Connection Monitor found (provisioning: $($cm.provisioningState))"
        # Query test results from Log Analytics (v2 writes to NWConnectionMonitorTestResult)
        $lawName = "$Prefix-law"
        $lawId = az monitor log-analytics workspace show -g $ResourceGroup -n $lawName --query customerId -o tsv 2>$null
        if ($lawId) {
            Write-Info "Querying Log Analytics workspace '$lawName' for CM test results..."
            $kql = @"
NWConnectionMonitorTestResult
| where TimeGenerated > ago(30m)
| summarize arg_max(TimeGenerated, *) by TestGroupName, SourceName, DestinationName
| project TestGroupName, SourceName, DestinationName, TestResult, ChecksFailed, ChecksTotal, AvgRoundTripTimeMs, TimeGenerated
| order by TestGroupName asc
"@
            $queryJson = az monitor log-analytics query `
                --workspace $lawId `
                --analytics-query $kql `
                -o json 2>&1
            if ($LASTEXITCODE -eq 0 -and $queryJson) {
                $results = ($queryJson | ConvertFrom-Json)
                # az monitor log-analytics query returns an array of tables; rows are in [0].rows or directly as objects
                $rows = if ($results -is [array] -and $results.Count -gt 0) {
                    if ($results[0].PSObject.Properties.Name -contains 'rows') { $results[0].rows } else { $results }
                } elseif ($results.PSObject.Properties.Name -contains 'tables') {
                    $results.tables[0].rows
                } else { $results }
                if ($null -eq $rows -or @($rows).Count -eq 0) {
                    Write-CheckWarn "Connection Monitor: no test results in the last 30 minutes (CM may still be collecting data)"
                } else {
                    foreach ($row in @($rows)) {
                        # Rows may be objects with named properties or positional arrays
                        if ($row -is [array]) {
                            $tg = $row[0]; $src = $row[1]; $dst = $row[2]; $result = $row[3]
                            $failed = $row[4]; $total = $row[5]; $rtt = $row[6]
                        } else {
                            $tg = $row.TestGroupName; $src = $row.SourceName; $dst = $row.DestinationName
                            $result = $row.TestResult; $failed = $row.ChecksFailed; $total = $row.ChecksTotal
                            $rtt = $row.AvgRoundTripTimeMs
                        }
                        $rttStr = if ($rtt) { "${rtt}ms" } else { "N/A" }
                        if ($result -eq "Pass" -or $result -eq "Passed") {
                            Write-CheckPass "CM $tg ($src -> $dst): PASS (RTT: $rttStr)"
                        } elseif ($result -eq "Fail" -or $result -eq "Failed") {
                            Write-CheckFail "CM $tg ($src -> $dst): FAIL — $failed/$total checks failed (RTT: $rttStr)"
                        } elseif ($result -eq "Indeterminate") {
                            Write-CheckWarn "CM $tg ($src -> $dst): Indeterminate (RTT: $rttStr)"
                        } else {
                            Write-CheckWarn "CM $tg ($src -> $dst): $result (RTT: $rttStr)"
                        }
                    }
                }
            } else {
                $errMsg = if ($queryJson) { ($queryJson | Out-String).Trim() } else { "no output" }
                if ($errMsg.Length -gt 200) { $errMsg = $errMsg.Substring(0, 200) }
                # Check if the table doesn't exist yet (CM hasn't sent data)
                if ($errMsg -match "SemanticError|BadArgumentError|could not be resolved") {
                    Write-CheckWarn "Connection Monitor: NWConnectionMonitorTestResult table not yet available (CM may need more time to generate data)"
                } else {
                    Write-CheckFail "Connection Monitor Log Analytics query failed: $errMsg"
                }
            }
        } else {
            Write-CheckWarn "Log Analytics workspace '$lawName' not found — cannot query CM test results"
        }
    } else {
        Write-CheckFail "Connection Monitor '$cmName' not found in NetworkWatcherRG"
    }
} catch {
    Write-CheckFail "Connection Monitor: could not query — $($_.Exception.Message)"
}

} # end section 12

###############################################################################
# 13. NVA Subnet Default Outbound Access
###############################################################################
if (ShouldRun 13) {
Write-Section "13. NVA Subnet Default Outbound Access"
foreach ($hub in @("hub1", "hub2")) {
    $vnetName = "$Prefix-$hub-vnet"
    Write-Info "Checking NvaSubnet outbound config on $vnetName..."
    try {
        $subnetJson = az network vnet subnet show -g $ResourceGroup --vnet-name $vnetName -n "NvaSubnet" -o json 2>$null
        if ($subnetJson) {
            $subnet = $subnetJson | ConvertFrom-Json

            # Check NAT Gateway association
            if ($subnet.natGateway -and $subnet.natGateway.id) {
                Write-CheckPass "$vnetName/NvaSubnet: NAT Gateway associated (reliable outbound)"
            } else {
                Write-CheckWarn "$vnetName/NvaSubnet: no NAT Gateway — relies on default outbound access (being deprecated by Azure)"
            }

            # Check for route table with 0/0 → None that would block internet
            if ($subnet.routeTable -and $subnet.routeTable.id) {
                $rtName = ($subnet.routeTable.id -split '/')[-1]
                $routesJson = az network route-table route list -g $ResourceGroup --route-table-name $rtName -o json 2>$null
                if ($routesJson) {
                    $routes = $routesJson | ConvertFrom-Json
                    $blockRoute = $routes | Where-Object { $_.addressPrefix -eq "0.0.0.0/0" -and $_.nextHopType -eq "None" }
                    if ($blockRoute) {
                        Write-CheckFail "$vnetName/NvaSubnet: route table '$rtName' has 0.0.0.0/0 → None — outbound internet BLOCKED"
                    } else {
                        Write-CheckPass "$vnetName/NvaSubnet: route table '$rtName' does not block internet (no 0/0 → None)"
                    }
                }
            } else {
                Write-CheckPass "$vnetName/NvaSubnet: no route table — default outbound not overridden by UDR"
            }

            # Check default outbound access property
            # With NAT Gateway present, defaultOutboundAccess=false is the desired state
            $hasNatGw = ($subnet.natGateway -and $subnet.natGateway.id)
            $defaultOutbound = $subnet.defaultOutboundAccess
            if ($null -eq $defaultOutbound) {
                Write-CheckWarn "$vnetName/NvaSubnet: defaultOutboundAccess property not set (depends on subscription default)"
            } elseif ($defaultOutbound -eq $false -and $hasNatGw) {
                Write-CheckPass "$vnetName/NvaSubnet: defaultOutboundAccess = false (correct — NAT Gateway provides outbound)"
            } elseif ($defaultOutbound -eq $false -and -not $hasNatGw) {
                Write-CheckFail "$vnetName/NvaSubnet: defaultOutboundAccess = false but NO NAT Gateway — NVAs cannot reach internet"
            } elseif ($defaultOutbound -eq $true) {
                Write-CheckWarn "$vnetName/NvaSubnet: defaultOutboundAccess = true (consider setting to false with NAT Gateway)"
            }
        } else {
            Write-CheckWarn "$vnetName/NvaSubnet: could not query subnet"
        }
    } catch {
        Write-CheckWarn "$vnetName/NvaSubnet: could not check outbound access"
    }
}

} # end section 13

###############################################################################
# 14. Application Endpoint HTTP Reachability
###############################################################################
if (ShouldRun 14) {
Write-Section "14. Application Endpoint HTTP Reachability (AppGW + Traffic Manager)"
# Resolve AppGW public FQDNs
foreach ($hub in @("hub1", "hub2")) {
    $pipName = "$Prefix-$hub-appgw-pip"
    try {
        $fqdn = az network public-ip show -g $ResourceGroup -n $pipName --query "dnsSettings.fqdn" -o tsv 2>$null
        if ($fqdn) {
            $url = "http://$fqdn/"
            Write-Info "Testing $url ..."
            try {
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                if ($resp.StatusCode -eq 200) {
                    Write-CheckPass "$hub AppGW ($fqdn): HTTP 200 OK"
                } else {
                    Write-CheckFail "$hub AppGW ($fqdn): HTTP $($resp.StatusCode)"
                }
            } catch {
                Write-CheckFail "$hub AppGW ($fqdn): request failed — $($_.Exception.Message)"
            }
        } else {
            Write-CheckWarn "$hub AppGW: PIP $pipName has no FQDN configured"
        }
    } catch {
        Write-CheckWarn "$hub AppGW: could not resolve PIP $pipName"
    }
}

# Traffic Manager endpoint
$tmName = "$Prefix-webapp"
try {
    $tmFqdn = az network traffic-manager profile show -g $ResourceGroup -n $tmName --query "dnsConfig.fqdn" -o tsv 2>$null
    if ($tmFqdn) {
        $url = "http://$tmFqdn/"
        Write-Info "Testing $url ..."
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                Write-CheckPass "Traffic Manager ($tmFqdn): HTTP 200 OK"
            } else {
                Write-CheckFail "Traffic Manager ($tmFqdn): HTTP $($resp.StatusCode)"
            }
        } catch {
            Write-CheckFail "Traffic Manager ($tmFqdn): request failed — $($_.Exception.Message)"
        }
    } else {
        Write-CheckWarn "Traffic Manager: profile $tmName has no FQDN"
    }
} catch {
    Write-CheckWarn "Traffic Manager: could not query profile $tmName"
}

} # end section 14

###############################################################################
# 16. Spoke VM Local Web Application (via run-command)
###############################################################################
if (ShouldRun 16) {
Write-Section "16. Spoke VM Local Web Application (curl localhost via run-command)"
foreach ($spoke in @("spoke11", "spoke12", "spoke21", "spoke22")) {
    $vmName = "$Prefix-$spoke-vm"
    Write-Info "Testing local web app on $vmName (this takes ~15-30s per VM)..."
    try {
        $resultJson = az vm run-command invoke -g $ResourceGroup -n $vmName `
            --command-id RunShellScript `
            --scripts "curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null" `
            -o json 2>$null
        if ($resultJson) {
            $result = $resultJson | ConvertFrom-Json
            $stdoutEntry = $result.value | Where-Object { $_.code -like "*stdout*" }
            $httpCode = if ($stdoutEntry -and $stdoutEntry.message) { $stdoutEntry.message.Trim() } else { "" }
            if ($httpCode -eq "200") {
                Write-CheckPass "$vmName`: local web app returns HTTP 200"
            } elseif ([string]::IsNullOrEmpty($httpCode) -or $httpCode -eq "000") {
                Write-CheckFail "$vmName`: web app not responding (Apache may not be installed/running)"
            } else {
                Write-CheckFail "$vmName`: web app returned HTTP $httpCode"
            }
        } else {
            Write-CheckWarn "$vmName`: run-command returned no output"
        }
    } catch {
        Write-CheckWarn "$vmName`: could not run command — $($_.Exception.Message)"
    }
}

} # end section 16

###############################################################################
# Summary
###############################################################################
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
$total = $script:PassCount + $script:FailCount
Write-Host "  Checks: $total   " -NoNewline
Write-Host "Passed: $($script:PassCount)   " -ForegroundColor Green -NoNewline
Write-Host "Failed: $($script:FailCount)" -ForegroundColor Red

if ($script:FailCount -eq 0) {
    Write-Host ""
    Write-Host "  ████ HEALTHY ████" -ForegroundColor Green
    Write-Host "  All checks passed. Environment is in expected state."
} else {
    Write-Host ""
    Write-Host "  ████ DEGRADED ████" -ForegroundColor Red
    Write-Host "  $($script:FailCount) issue(s) detected:"
    Write-Host ""
    foreach ($f in $script:Failures) {
        Write-Host "    • $f" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Run .\revert-all.ps1 -ResourceGroup $ResourceGroup -Prefix $Prefix to fix." -ForegroundColor Cyan
}
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
