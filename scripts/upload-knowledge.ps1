<#
.SYNOPSIS
    Upload knowledge base files to the SRE Agent.

.DESCRIPTION
    The SRE Agent knowledge base cannot be configured via Bicep.
    This script checks if the agent exists and provides instructions
    for uploading knowledge files via the SRE Agent portal.

.PARAMETER AgentName
    Name of the SRE Agent resource. Default: netsre-sre-agent

.PARAMETER ResourceGroup
    Resource group containing the SRE Agent. Default: netsre-rg

.PARAMETER KnowledgeDir
    Path to the knowledge directory containing markdown files.
#>

param(
    [string]$AgentName = "netsre-sre-agent",
    [string]$ResourceGroup = "netsre-rg",
    [string]$KnowledgeDir = "$PSScriptRoot\..\knowledge"
)

$ErrorActionPreference = "Stop"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " SRE Agent Knowledge Base Upload" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Agent:          $AgentName"
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Knowledge Dir:  $KnowledgeDir"
Write-Host ""

# Verify knowledge directory
if (-not (Test-Path $KnowledgeDir)) {
    Write-Host "ERROR: Knowledge directory not found: $KnowledgeDir" -ForegroundColor Red
    exit 1
}

# Count files
$mdFiles = Get-ChildItem -Path $KnowledgeDir -Filter "*.md" -File
Write-Host "Found $($mdFiles.Count) markdown file(s)." -ForegroundColor Green
Write-Host ""

if ($mdFiles.Count -eq 0) {
    Write-Host "No markdown files found. Nothing to upload."
    exit 0
}

# Check if agent exists
Write-Host "Looking up SRE Agent resource..."
try {
    $agentJson = az resource show `
        --resource-group $ResourceGroup `
        --resource-type "Microsoft.App/agents" `
        --name $AgentName `
        --query "id" -o tsv 2>$null
    Write-Host "Agent ID: $agentJson" -ForegroundColor Green
} catch {
    Write-Host "WARNING: SRE Agent '$AgentName' not found in '$ResourceGroup'." -ForegroundColor Yellow
    Write-Host "Deploy the agent first using the Bicep templates." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " KNOWLEDGE BASE UPLOAD INSTRUCTIONS" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "The SRE Agent knowledge base must be uploaded via the portal:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Go to https://sre.azure.com" -ForegroundColor White
Write-Host "  2. Select agent: $AgentName" -ForegroundColor White
Write-Host "  3. Navigate to: Builder > Knowledge base" -ForegroundColor White
Write-Host "  4. Click 'Upload files'" -ForegroundColor White
Write-Host "  5. Select all .md files from the knowledge directory" -ForegroundColor White
Write-Host ""
Write-Host "Files to upload:" -ForegroundColor Green
foreach ($file in $mdFiles) {
    $sizeKB = [math]::Round($file.Length / 1024, 1)
    Write-Host "  - $($file.Name) ($sizeKB KB)"
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " POST-UPLOAD CONFIGURATION" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "After uploading, configure in the portal:" -ForegroundColor White
Write-Host ""
Write-Host "1. RESPONSE PLAN:" -ForegroundColor Yellow
Write-Host "   Builder > Response Plans > Create:" -ForegroundColor White
Write-Host "   - Name: networking-incident-handler" -ForegroundColor White
Write-Host "   - Filter: Severity Sev0, Sev1, Sev2" -ForegroundColor White
Write-Host "   - Autonomy: Review" -ForegroundColor White
Write-Host "   - Instructions: 'Investigate NVA IP forwarding, iptables," -ForegroundColor White
Write-Host "     UDR routes, NSG rules, VPN, BGP, NAT gateway, peerings.'" -ForegroundColor White
Write-Host ""
Write-Host "2. CONNECTORS:" -ForegroundColor Yellow
Write-Host "   - Azure Monitor: Connected by default" -ForegroundColor White
Write-Host "   - Log Analytics: Connect to workspace '$($AgentName -replace '-sre-agent','')-law'" -ForegroundColor White
Write-Host ""
Write-Host "3. CUSTOM AGENTS (optional):" -ForegroundColor Yellow
Write-Host "   Builder > Custom agents for specialized sub-agents." -ForegroundColor White
