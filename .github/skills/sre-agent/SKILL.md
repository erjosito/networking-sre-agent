---
name: sre-agent
description: "Guide for deploying, configuring, testing, and troubleshooting the Azure Networking SRE Agent testbed. Use when working on this repository: deploying infrastructure, injecting faults, running health checks, configuring the SRE agent, debugging connectivity or DNS issues, or modifying Bicep templates."
allowed-tools: shell
---

# Azure Networking SRE Agent Testbed

This skill provides operational knowledge for the networking-sre-agent repository — a multi-hub Azure lab paired with the Azure SRE Agent for automated incident detection and troubleshooting.

## Repository Structure

```
infra/main.bicep              — Top-level Bicep orchestration
infra/modules/*.bicep         — Individual modules (hub, spoke, onprem, vpn-connections, private-link, appgw, traffic-manager, connection-monitors, alerts, sre-agent)
scripts/deploy.ps1            — Full deployment + post-deploy config
scripts/check-health.ps1      — 20-section environment validation
scripts/inject-fault.ps1      — 26 fault scenarios across 6 categories
scripts/upload-knowledge.ps1  — Upload knowledge files to SRE Agent
sre-agent-config/             — Agent config manifest, custom agents, skills
knowledge/                    — 13 markdown files for SRE Agent knowledge base
ref/                          — Reference material (gitignored, not committed)
```

## Deployment

### Deploy the full environment

```powershell
.\scripts\deploy.ps1 -ResourceGroup "netsre-rg" -Location "eastus2" -Prefix "netsre"
```

Deployment takes ~30-45 minutes (VPN Gateways are the bottleneck). The script:
1. Creates the resource group
2. Deploys main.bicep (all modules) **via a generated parameters JSON file** (never inline `key=value` — the SSH public key breaks inline parsing; see Common Issues)
3. Enables Storage Account static website (`--auth-mode login`)
4. Uploads index.html for HTTP probes
5. Deploys connection monitors to NetworkWatcherRG

**Required deployment inputs beyond defaults:**
- `vpnSharedKey` — required by `main.bicep` (no default). `deploy.ps1` defaults it to `TestVpnKey2025!`.
- SRE Agent: no sponsor group / agent identity required. The agent is deployed with a **SystemAssigned + UserAssigned** identity and **no** `properties.agentIdentity` block — this avoids the per-tenant "not allowed to create agent identities" gate. `-SreAgentSponsorGroupId` is deprecated/ignored; skip the agent with `-DeploySreAgent $false`. Verified working in eastus2 and canadacentral.
- For long/unattended runs, submit with `--no-wait` so the deployment survives a disconnected shell, then poll `az deployment group list`/`... wait`. 0 registered deployments after a submit = a client-side parameter error, not a slow ARM.

### Deploy individual modules (when full redeploy fails)

You cannot change `osProfile.customData` on existing VMs, so full redeployments may fail with `PropertyChangeNotAllowed`. Deploy changed modules individually:

```powershell
az deployment group create -g netsre-rg --template-file infra/modules/private-link.bicep --parameters prefix=netsre location=eastus2 ...
```

### Subscription policy: key-based auth blocked

The subscription blocks `allowSharedKeyAccess` on storage accounts. This means:
- `Microsoft.Resources/deploymentScripts` (AzureCLI kind) will fail because ACI uses key auth internally
- **Workaround**: Static website setup is a post-deployment CLI step using `--auth-mode login`
- The deploying user needs `Storage Blob Data Contributor` role on the storage account

### Static website post-deployment

```powershell
$sa = az storage account list -g netsre-rg --query "[?starts_with(name,'netsreweb')].name" -o tsv
az storage blob service-properties update --account-name $sa --static-website --index-document index.html --auth-mode login
az storage blob upload --account-name $sa --container-name '$web' --name index.html --file infra/static-web/index.html --auth-mode login --overwrite
```

## Health Checks

```powershell
.\scripts\check-health.ps1                    # All 20 sections
.\scripts\check-health.ps1 -Sections 5,20    # Specific sections
.\scripts\check-health.ps1 -ListSections     # Show section names
```

### Key sections
| # | Section | Validates |
|---|---------|-----------|
| 5 | Route Tables | UDRs with correct next-hops |
| 6 | NVA VMs | IP forwarding, OS forwarding, dnsmasq |
| 9 | VPN Connections | S2S status and BGP sessions |
| 16 | Spoke Web Apps | Apache serving HTTP 200 (via `az vm run-command`) |
| 17 | Private Endpoint | PE exists, approved, correct IP |
| 20 | Static Website DNS | DNS resolution from VMs + VNet DNS config |

### Parsing `az vm run-command` output in PowerShell

**Critical pattern**: `az vm run-command invoke --query "value[0].message" -o tsv` returns a `System.Object[]` array in PowerShell, not a string. You must join before regex:

```powershell
$resultRaw = az vm run-command invoke -g $rg -n $vm --command-id RunShellScript --scripts "..." --query "value[0].message" -o tsv
$resultMsg = if ($resultRaw -is [array]) { $resultRaw -join "`n" } else { $resultRaw }
if ($resultMsg -match '(?s)\[stdout\]\s*(.*?)\s*\[stderr\]') {
    $output = $matches[1].Trim()
}
```

## Fault Injection

```powershell
.\scripts\inject-fault.ps1 -List                          # Show all scenarios
.\scripts\inject-fault.ps1 -Scenario <name>               # Inject
.\scripts\inject-fault.ps1 -Scenario <name> -Revert       # Revert
```

### Categories and scenarios

**IP Forwarding**: `ip-forwarding-hub1`, `ip-forwarding-hub2`
**UDR**: `udr-wrong-nexthop`, `udr-missing-route`, `udr-detach`
**NSG**: `nsg-block-icmp`, `nsg-block-all`, `nsg-block-ssh`
**NVA**: `nva-iptables-drop`, `nva-iptables-block-spoke`, `nva-os-forwarding`, `nva-stop-ssh`, `nva-no-internet`
**VPN/BGP**: `vpn-disconnect`, `bgp-propagation`, `gw-disable-bgp-propagation`, `gateway-nsg`
**Peering**: `peering-disconnect`, `peering-no-gateway-transit`, `peering-no-use-remote-gw`
**Private Link**: `pe-nsg-block`, `pe-dns-break`, `pe-route-missing`, `pe-dns-override`
**AppGW**: `appgw-probe-misconfigure`
**Combo**: `multi-fault`

### Design principles for fault scenarios
- Each scenario must have a clean `-Revert` path
- The `pe-dns-override` scenario reboots the VM to force DHCP renewal (DNS changes don't take effect until lease renewal)
- Avoid scenarios that don't have observable effects (e.g., rejecting a PE connection on an existing endpoint has no effect)
- Prefer subtle, realistic faults (e.g., changing VNet DNS to Azure default — only PE breaks while everything else works)

## Architecture Key Facts

### Routing
- **All traffic traverses the NVA** (spoke-to-spoke, spoke-to-onprem, spoke-to-PE, onprem-to-PE)
- GatewaySubnet route table has `10.1.4.0/24 → NVA LB` to force on-prem→PE through NVA
- Spoke subnets have `10.1.4.0/24 → NVA LB` to override the /32 InterfaceEndpoint system route
- PE subnet route table has return routes for all spokes and on-prem → NVA LB
- BGP route propagation is DISABLED on spoke route tables (forces traffic through NVA)

### DNS
- Spokes use NVA LB IP as custom DNS (hub1 spokes → 10.1.1.200, hub2 → 10.2.1.200)
- On-prem uses both NVA LBs as DNS servers
- NVAs run **dnsmasq** forwarding to Azure DNS (168.63.129.16)
- Private DNS zone `privatelink.web.core.windows.net` linked to **hub VNets only** (not spokes, not on-prem)
- Resolution chain: spoke VM → NVA dnsmasq → Azure DNS → Private DNS Zone → PE IP (10.1.4.4)
- dnsmasq must be configured to listen on all interfaces (`listen-address=0.0.0.0` or bind to eth0 IP)

### Private Endpoint
- Storage Account with static website, accessed via PE in Hub1 PrivateEndpointSubnet (10.1.4.4)
- PE sub-resource groupId is `web` (not `blob`)
- DNS zone is `privatelink.web.core.windows.net`
- Static website FQDN zone suffix is region-specific (e.g., `z20` for eastus2)
- Connection Monitor uses HTTP 443 probes expecting status 200

### VPN/BGP
- Three VPN Gateways: hub1 (ASN 65001), hub2 (ASN 65002), on-prem (ASN 65100)
- On-prem connects to both hubs via S2S VPN with BGP
- VPN shared key: `TestVpnKey2025!` (for fault injection revert)

### NVA Configuration
- Ubuntu 22.04 with: `net.ipv4.ip_forward=1`, iptables SNAT for non-RFC1918, dnsmasq
- Behind Standard Internal LB (hub1: 10.1.1.200, hub2: 10.2.1.200)
- NIC-level IP forwarding enabled in Azure

## SRE Agent Configuration

### Agent resource
- API: `Microsoft.App/agents@2025-05-01-preview`
- Mode: Autonomous, Access: High, Model: Automatic
- Has Azure Monitor connector for alert integration
- Managed identity with Network Contributor + Reader on the infrastructure RG

### Response plan isolation
- Alert names use pattern `<prefix>-cm-checks-failed`
- Response plans use `titleContains` field to filter by prefix
- This allows multiple deployments in the same subscription without interference

### Configuration artifacts
- `sre-agent-config/config.yaml` — declarative manifest (knowledge, agents, skills, response plans)
- `sre-agent-config/custom-agents/` — network-expert and connectivity-triage agent definitions
- `sre-agent-config/skills/` — NVA troubleshooting, VPN/BGP diagnostics, PE/DNS resolution guides

## Connection Monitors

Deployed to `NetworkWatcherRG` (not the main RG). 11 test groups:
- Spoke-to-spoke (intra-hub and cross-hub)
- Spoke/onprem-to-internet
- Onprem-to-webapp (via Traffic Manager)
- Spoke/onprem-to-staticweb (HTTPS 443, expect HTTP 200)

**Important**: Connection Monitor probes use the Network Watcher agent extension which resolves DNS via Azure infrastructure DNS — different from the VM's configured DNS. This means CM probes may succeed even when VM-level DNS resolution is broken.

## On-Prem Networking Extension (optional add-on)

Extends the lab to **on-premises networking** (device simulation, telemetry, audit, and detection). Design doc: `docs/onprem-network-simulation-and-telemetry.md`. Deployed by `scripts/deploy-onprem.ps1 -Stage telemetry|device|containerlab|all` on top of an existing lab. All pieces are **optional, independently-deployable add-on modules** (`infra/modules/onprem-*.bicep`) that never modify `main.bicep`/`onprem.bicep`.

### Stages and modules
- **Stage 0 — telemetry** (`onprem-collector.bicep`, `cloud-init/collector.yaml`): collector VM at `10.100.1.100` running rsyslog (514), snmpd, and Telegraf (SNMP → Azure Monitor custom metrics). AMA + a Syslog DCR/DCRA ship to `${prefix}-law`. Telegraf uses managed identity → needs **Monitoring Metrics Publisher** role at VM scope.
- **Stage 1 — in-path device + detection** (`onprem-router.bicep`, `onprem-lan.bicep`, `onprem-connection-monitor.bicep`, `onprem-alerts.bicep`): FRR router-on-a-stick at `10.100.1.201`; on-prem server in a new `onprem-lan` subnet (`10.100.2.0/24`) behind it. UDRs force the data path through FRR (LAN `0/0`→FRR; GatewaySubnet `10.100.2.0/24`→FRR). CM + metric alerts detect a device fault.
- **Stage A2 — Containerlab** (`onprem-containerlab.bicep`, `cloud-init/containerlab-host.yaml`, `infra/containerlab/`): high-fidelity option — a host VM runs Docker + Containerlab and boots a containerized fabric (2× FRR eBGP + a Linux server). Self-contained (not in the Azure data path).

### Key design decisions & lessons
- **CM sources are two Azure spokes (`spoke11` + `spoke21`), NOT the on-prem VM.** The on-prem VM sits in the `default` subnet with no UDR, so it reaches `onprem-lan` via the **direct VNet system route, bypassing FRR** → a false "pass" when FRR is broken. Spoke sources arrive via the VPN gateway → GatewaySubnet UDR → FRR, so they genuinely transit the device. Using one spoke per hub also tests both hubs and enables fault localization (on-prem-server probes fail while spoke-to-spoke still pass).
- **Intra-VNet UDR subtlety:** a `0/0`→FRR UDR is *less specific* than the VNet `/16` system route, so server↔collector (both in `10.100.0.0/16`) stays direct; only non-VNet traffic transits FRR — intended.
- **Subnet write serialization:** multiple `virtualNetworks/subnets` writes on the same VNet must be serialized via `dependsOn` (GatewaySubnet UDR depends on the LAN subnet) or they conflict. Re-declaring GatewaySubnet as a standalone child resource updates it in place (additive, safe).
- **Cloud-init injection:** collector IP and repo branch are injected via `replace(loadTextContent(...), 'PLACEHOLDER', value)` then base64 — same pattern as the hub NVAs.
- **Containerlab host** clones this repo branch on boot and runs `containerlab deploy`; a systemd unit re-deploys after reboot because clab veth links are lost. FRR runs as `kind: linux` (`quay.io/frrouting/frr`); node CLI via `docker exec -it clab-onprem-onprem-r1 vtysh`. SR Linux (`ghcr.io/nokia/srlinux`, publicly pullable) is the vendor-fidelity upgrade.
- **Detection strategy:** keep the existing **data-plane** Connection Monitor alerts as the primary trigger; treat control-plane (BGP)/audit (AAA) signals as enrichment (design doc Part D).

## Teardown

```powershell
.\scripts\teardown.ps1 -ResourceGroup "netsre-rg"
# Or manually:
az group delete -n netsre-rg --yes --no-wait
```

Also delete: SRE agent (if in separate RG), connection monitors in NetworkWatcherRG.

## Common Issues and Solutions

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| `PropertyChangeNotAllowed` on VMs | Can't change customData on existing VMs | Deploy modules individually |
| `Key based authentication is not permitted` | Subscription policy | Use `--auth-mode login` for all storage ops |
| Health check DNS section shows false failures | `az vm run-command -o tsv` returns array | Join with `-join "\`n"` before regex |
| DNS works from VM but health check reports failure | grep/awk pipeline parsing difference | Use `[stdout]...[stderr]` regex extraction |
| PE DNS override fault doesn't take effect | VM needs DHCP lease renewal | Reboot VM after changing VNet DNS |
| dnsmasq running but not responding | Listening on 127.0.0.1 only | Set `listen-address=0.0.0.0` and restart |
| CM probes succeed but VM DNS fails | NW agent uses Azure DNS directly | Not a bug — CM bypasses VNet DNS settings |
| SRE agent deploy fails: `DefaultModelName is invalid ... 'gpt-5' is not available in this region` | Model hardcoded/region-restricted | Set `sreAgentModelName` to `Automatic` (default) or a region-available model (e.g. `gpt-5.4`) |
| SRE agent deploy spins ~20-45 min then fails `The resource provision operation did not complete within the allowed timeout period` — op stays `Running`, `statusMessage` shows `Tenant <id> is not allowed to create agent identities` | **RESOLVED.** Root cause was the module setting `properties.agentIdentity.initialSponsorGroupId`, which asks the platform to create a first-party **agent identity** — gated per-tenant. | Do **not** set `properties.agentIdentity` / sponsor group. Deploy the agent with a `SystemAssigned, UserAssigned` identity instead (mirrors the portal-created agent, which has `agentIdentity: null`). `sre-agent.bicep` now does this and provisions cleanly (verified eastus2 + canadacentral). |
| Containerlab FRR `bgpd` won't start (`getaddrinfo failed`), zebra runs, no `router bgp` in show run | CRLF line endings add trailing CR to `/etc/frr/daemons` values | Configs must be LF; repo ships `.gitattributes` forcing LF for `infra/containerlab/configs/**` |
| `index.html` upload fails: `request may be blocked by network rules` and public access won't stay enabled | Azure Policy forces `publicNetworkAccess=Disabled`; the `web` PE doesn't expose the `blob` endpoint | No in-VNet blob path. Add a temporary `blob` PE + upload from a hub VM, or get a policy exemption to enable public access briefly |
| `az deployment group create` hangs for minutes / `Unable to parse parameter` / 0 deployments registered | Inline `--parameters key=value` breaks on values with spaces or `=` (the SSH public key) — a client-side parse failure before submission | Pass a **parameters JSON file** (`--parameters "@file.json"`); `deploy.ps1` now does this. Diagnose with `--debug` to a file; `az deployment group list` showing 0 = client-side failure |
| Deployment fails: missing required `vpnSharedKey` | `main.bicep` requires it (no default) | `deploy.ps1 -VpnSharedKey` (default `TestVpnKey2025!`) |
| SRE agent deploy fails: `InvalidApplicationInsightsConfiguration: The AppId and ConnectionString fields must be provided together` | `logConfiguration.applicationInsightsConfiguration` had `appId` + `applicationInsightsResourceId` | Provide `appId` **and** `connectionString` together (not `applicationInsightsResourceId`). `sre-agent.bicep` does this. |
| `az --query "length(@)"` errors `-o was unexpected at this time` (PowerShell) | cmd mangles the `(@)` | Use `(az ... -o json | ConvertFrom-Json).Count` |
