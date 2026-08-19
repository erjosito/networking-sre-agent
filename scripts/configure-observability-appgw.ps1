<#
.SYNOPSIS
    Configure optional, CIDR-restricted public ingress to the Observability API.

.DESCRIPTION
    Adds a dedicated HTTP listener on the existing Hub1 Application Gateway and
    routes it to the private Observability API VM on port 8080. Public access is
    restricted at the Application Gateway subnet NSG to the supplied presenter
    IPv4 address or CIDR. Backend traffic remains private and follows the lab's
    existing symmetric Hub1 AppGW-to-spoke route through the NVA.

    HTTP is acceptable for this lab because requests contain no credentials or
    payload secrets. Production deployments should use HTTPS with a managed
    certificate and an appropriate TLS policy.

.PARAMETER AllowedSourceCidr
    Presenter public IPv4 address or CIDR allowed to reach the frontend port.
    Required when enabling ingress.

.PARAMETER FrontendPort
    Dedicated public frontend port. Defaults to 8080. Backend traffic always
    targets the API VM on port 8080.

.PARAMETER Disable
    Remove the optional NSG rule and Application Gateway objects.

.EXAMPLE
    .\scripts\configure-observability-appgw.ps1 `
      -AllowedSourceCidr '<presenter-public-ip>/32'

.EXAMPLE
    .\scripts\configure-observability-appgw.ps1 -Disable
#>

[CmdletBinding(DefaultParameterSetName = "Enable")]
param(
    [string]$ResourceGroup = $env:RESOURCE_GROUP ?? "netsre-rg",
    [string]$Prefix = $env:PREFIX ?? "netsre",
    [Parameter(Mandatory, ParameterSetName = "Enable")]
    [ValidatePattern('^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:/(?:[0-9]|[12]\d|3[0-2]))?$')]
    [string]$AllowedSourceCidr,
    [ValidateRange(1, 65535)]
    [int]$FrontendPort = 8080,
    [Parameter(Mandatory, ParameterSetName = "Disable")]
    [switch]$Disable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "[OK]    $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AsJson
    )

    $effectiveArguments = $Arguments + @("--only-show-errors")
    $output = & az @effectiveArguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($exitCode -ne 0) {
        throw "Azure CLI command failed (exit $exitCode): az $($Arguments -join ' ')`n$text"
    }

    if (-not $AsJson) {
        return $text.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        throw "Azure CLI returned invalid JSON for: az $($Arguments -join ' ')`n$text"
    }
}

function Test-NamedItem {
    param($Items, [string]$Name)
    return @($Items | Where-Object { $_.name -eq $Name }).Count -gt 0
}

function Wait-AppGatewayRunning {
    param([string]$GatewayName)

    $gateway = Invoke-AzCli -Arguments @(
        "network", "application-gateway", "show",
        "--resource-group", $ResourceGroup,
        "--name", $GatewayName,
        "--output", "json"
    ) -AsJson

    if ($gateway.operationalState -eq "Running") {
        Write-Ok "$GatewayName is already running."
        return $gateway
    }

    Write-Info "Starting $GatewayName from '$($gateway.operationalState)'..."
    Invoke-AzCli -Arguments @(
        "network", "application-gateway", "start",
        "--resource-group", $ResourceGroup,
        "--name", $GatewayName,
        "--output", "none"
    ) | Out-Null

    $deadline = (Get-Date).AddMinutes(15)
    do {
        $gateway = Invoke-AzCli -Arguments @(
            "network", "application-gateway", "show",
            "--resource-group", $ResourceGroup,
            "--name", $GatewayName,
            "--output", "json"
        ) -AsJson
        if ($gateway.operationalState -eq "Running") {
            Write-Ok "$GatewayName is running."
            return $gateway
        }
        Write-Info "Waiting for $GatewayName (state: $($gateway.operationalState))..."
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $GatewayName to reach Running."
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or later is required."
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed. See https://aka.ms/install-azure-cli"
}
if (-not $Disable -and $AllowedSourceCidr -match '/0$') {
    throw "AllowedSourceCidr cannot use a /0 prefix. Supply the presenter's public IPv4 address, normally as a /32."
}
Invoke-AzCli -Arguments @("account", "show", "--output", "none") | Out-Null

$GatewayName = "$Prefix-hub1-appgw"
$PublicIpName = "$Prefix-hub1-appgw-pip"
$NsgName = "$Prefix-hub1-appgw-nsg"
$ApiVmName = "$Prefix-observability-api"
$BackendPoolName = "observability-api-pool"
$ProbeName = "observability-api-probe"
$HttpSettingsName = "observability-api-http"
$FrontendPortName = "observability-api-port"
$ListenerName = "observability-api-listener"
$RuleName = "observability-api-rule"
$NsgRuleName = "observability-api-ingress"
$FrontendIpName = "appgw-feip"
$RulePriority = 200
$BackendPort = 8080

Write-Info "Resolving Hub1 Application Gateway and subnet NSG..."
$Gateway = Wait-AppGatewayRunning -GatewayName $GatewayName
$Nsg = Invoke-AzCli -Arguments @(
    "network", "nsg", "show",
    "--resource-group", $ResourceGroup,
    "--name", $NsgName,
    "--output", "json"
) -AsJson

if ($Disable) {
    if (Test-NamedItem -Items $Nsg.securityRules -Name $NsgRuleName) {
        Write-Info "Deleting NSG rule '$NsgRuleName' first so cleanup fails closed..."
        Invoke-AzCli -Arguments @(
            "network", "nsg", "rule", "delete",
            "--resource-group", $ResourceGroup,
            "--nsg-name", $NsgName,
            "--name", $NsgRuleName,
            "--output", "none"
        ) | Out-Null
    }
    $deletePlan = @(
        @{ Collection = $Gateway.requestRoutingRules; Group = "rule"; Name = $RuleName },
        @{ Collection = $Gateway.httpListeners; Group = "http-listener"; Name = $ListenerName },
        @{ Collection = $Gateway.backendHttpSettingsCollection; Group = "http-settings"; Name = $HttpSettingsName },
        @{ Collection = $Gateway.probes; Group = "probe"; Name = $ProbeName },
        @{ Collection = $Gateway.backendAddressPools; Group = "address-pool"; Name = $BackendPoolName },
        @{ Collection = $Gateway.frontendPorts; Group = "frontend-port"; Name = $FrontendPortName }
    )
    foreach ($item in $deletePlan) {
        if (Test-NamedItem -Items $item.Collection -Name $item.Name) {
            Write-Info "Deleting Application Gateway $($item.Group) '$($item.Name)'..."
            Invoke-AzCli -Arguments @(
                "network", "application-gateway", $item.Group, "delete",
                "--resource-group", $ResourceGroup,
                "--gateway-name", $GatewayName,
                "--name", $item.Name,
                "--output", "none"
            ) | Out-Null
        }
    }
    Write-Ok "Optional Observability API ingress is disabled."
    return
}

$ApiPrivateIp = Invoke-AzCli -Arguments @(
    "vm", "list-ip-addresses",
    "--resource-group", $ResourceGroup,
    "--name", $ApiVmName,
    "--query", "[0].virtualMachine.network.privateIpAddresses[0]",
    "--output", "tsv"
)
if ([string]::IsNullOrWhiteSpace($ApiPrivateIp)) {
    throw "Could not resolve the private IP of $ApiVmName. Deploy the Observability extension first."
}

$priorityConflict = @($Gateway.requestRoutingRules | Where-Object {
    $_.name -ne $RuleName -and [int]$_.priority -eq $RulePriority
}) | Select-Object -First 1
if ($priorityConflict) {
    throw "Application Gateway rule priority $RulePriority is already used by '$($priorityConflict.name)'."
}

$portConflict = @($Gateway.frontendPorts | Where-Object {
    $_.name -ne $FrontendPortName -and [int]$_.port -eq $FrontendPort
}) | Select-Object -First 1
if ($portConflict) {
    throw "Application Gateway frontend port $FrontendPort is already defined by '$($portConflict.name)'."
}

$otherPriorities = [System.Collections.Generic.HashSet[int]]::new()
foreach ($rule in @($Nsg.securityRules | Where-Object { $_.name -ne $NsgRuleName })) {
    [void]$otherPriorities.Add([int]$rule.priority)
}
$NsgPriority = 125
while ($NsgPriority -le 4096 -and $otherPriorities.Contains($NsgPriority)) {
    $NsgPriority++
}
if ($NsgPriority -gt 4096) {
    throw "No available NSG priority exists for '$NsgRuleName'."
}

$objectPlan = @(
    @{
        Collection = $Gateway.backendAddressPools
        Group = "address-pool"
        Name = $BackendPoolName
        Settings = @("--servers", $ApiPrivateIp)
    },
    @{
        Collection = $Gateway.probes
        Group = "probe"
        Name = $ProbeName
        Settings = @(
            "--protocol", "Http",
            "--host", "127.0.0.1",
            "--path", "/healthz",
            "--port", "$BackendPort",
            "--interval", "30",
            "--timeout", "30",
            "--threshold", "3",
            "--match-status-codes", "200-399"
        )
    },
    @{
        Collection = $Gateway.backendHttpSettingsCollection
        Group = "http-settings"
        Name = $HttpSettingsName
        Settings = @(
            "--port", "$BackendPort",
            "--protocol", "Http",
            "--cookie-based-affinity", "Disabled",
            "--timeout", "30",
            "--probe", $ProbeName
        )
    },
    @{
        Collection = $Gateway.frontendPorts
        Group = "frontend-port"
        Name = $FrontendPortName
        Settings = @("--port", "$FrontendPort")
    },
    @{
        Collection = $Gateway.httpListeners
        Group = "http-listener"
        Name = $ListenerName
        Settings = @("--frontend-ip", $FrontendIpName, "--frontend-port", $FrontendPortName)
    },
    @{
        Collection = $Gateway.requestRoutingRules
        Group = "rule"
        Name = $RuleName
        Settings = @(
            "--rule-type", "Basic",
            "--priority", "$RulePriority",
            "--http-listener", $ListenerName,
            "--address-pool", $BackendPoolName,
            "--http-settings", $HttpSettingsName
        )
    }
)

foreach ($item in $objectPlan) {
    $action = if (Test-NamedItem -Items $item.Collection -Name $item.Name) { "update" } else { "create" }
    Write-Info "$($action.Substring(0, 1).ToUpperInvariant())$($action.Substring(1)) Application Gateway $($item.Group) '$($item.Name)'..."
    $arguments = @(
        "network", "application-gateway", $item.Group, $action,
        "--resource-group", $ResourceGroup,
        "--gateway-name", $GatewayName,
        "--name", $item.Name
    ) + $item.Settings + @("--output", "none")
    Invoke-AzCli -Arguments $arguments | Out-Null
}

$nsgAction = if (Test-NamedItem -Items $Nsg.securityRules -Name $NsgRuleName) { "update" } else { "create" }
Write-Info "$($nsgAction.Substring(0, 1).ToUpperInvariant())$($nsgAction.Substring(1)) CIDR-restricted NSG rule '$NsgRuleName'..."
Invoke-AzCli -Arguments @(
    "network", "nsg", "rule", $nsgAction,
    "--resource-group", $ResourceGroup,
    "--nsg-name", $NsgName,
    "--name", $NsgRuleName,
    "--priority", "$NsgPriority",
    "--direction", "Inbound",
    "--access", "Allow",
    "--protocol", "Tcp",
    "--source-address-prefixes", $AllowedSourceCidr,
    "--source-port-ranges", "*",
    "--destination-address-prefixes", "*",
    "--destination-port-ranges", "$FrontendPort",
    "--description", "Allow Observability API demo ingress from the presenter CIDR only.",
    "--output", "none"
) | Out-Null

$PublicIp = Invoke-AzCli -Arguments @(
    "network", "public-ip", "show",
    "--resource-group", $ResourceGroup,
    "--name", $PublicIpName,
    "--output", "json"
) -AsJson
$EndpointHost = if ($PublicIp.dnsSettings -and $PublicIp.dnsSettings.fqdn) {
    $PublicIp.dnsSettings.fqdn
} else {
    $PublicIp.ipAddress
}
if ([string]::IsNullOrWhiteSpace($EndpointHost)) {
    throw "Hub1 Application Gateway public IP has neither an IP address nor an FQDN."
}
$Endpoint = "http://${EndpointHost}:$FrontendPort"

Write-Info "Waiting for the public health endpoint to become ready..."
$deadline = (Get-Date).AddMinutes(5)
$lastStatus = 0
$lastBody = ""
$lastError = ""
$health = $null
do {
    try {
        $response = Invoke-WebRequest -Uri "$Endpoint/healthz" -Method Get `
            -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
        $lastStatus = [int]$response.StatusCode
        $lastBody = [string]$response.Content
        $health = $null
        try {
            $health = $lastBody | ConvertFrom-Json
        } catch {
            $lastError = "HTTP $lastStatus returned invalid JSON: $($_.Exception.Message)"
        }
        if ($lastStatus -eq 200 -and $health -and $health.status -eq "ok") {
            Write-Ok "Observability API health verified through Hub1 Application Gateway."
            break
        }
        if ($health) {
            $lastError = "HTTP $lastStatus returned health status '$($health.status)'"
        } elseif ([string]::IsNullOrWhiteSpace($lastBody)) {
            $lastError = "HTTP $lastStatus returned an empty body"
        }
    } catch {
        $lastStatus = 0
        $lastBody = ""
        $lastError = $_.Exception.Message
    }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt $deadline)

if ($lastStatus -ne 200 -or -not $health -or $health.status -ne "ok") {
    Write-Warn "Last health result: $lastError $lastBody"
    Write-Warn "Inspect backend health with:"
    Write-Warn "  az network application-gateway show-backend-health -g `"$ResourceGroup`" -n `"$GatewayName`" -o jsonc"
    try {
        $backendHealth = Invoke-AzCli -Arguments @(
            "network", "application-gateway", "show-backend-health",
            "--resource-group", $ResourceGroup,
            "--name", $GatewayName,
            "--query", "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,probe:healthProbeLog}",
            "--output", "table"
        )
        if ($backendHealth) {
            Write-Host $backendHealth
        }
    } catch {
        Write-Warn "Backend health query also failed: $($_.Exception.Message)"
    }
    throw "GET $Endpoint/healthz did not return HTTP 200 with status 'ok'. Verify the presenter CIDR and AppGW backend health."
}

Write-Host ""
Write-Ok "Observability API public ingress configured."
Write-Host "  Endpoint       : $Endpoint"
Write-Host "  Allowed source : $AllowedSourceCidr"
Write-Host "  Frontend path  : Presenter -> Hub1 AppGW TCP/$FrontendPort"
Write-Host "  Backend path   : Hub1 AppGW -> NVA -> API private IP ${ApiPrivateIp}:$BackendPort"
Write-Warn "HTTP is for this credential-free lab demo only. Use HTTPS and a managed certificate in production."
Write-Output $Endpoint
