# Azure Networking SRE Agent — Test Environment

A ready-to-deploy Azure lab that builds a **multi-hub, hub-spoke network topology** complete with VPN gateways, NVA firewalls, and spoke workloads. It is designed to pair with the [Azure SRE Agent](https://sre.azure.com) (preview) so the agent can detect, investigate, and help resolve realistic networking incidents.

The repository includes:

- **Bicep infrastructure-as-code** for the full topology
- **Knowledge base documents** that teach the SRE Agent about Azure networking
- **Fault-injection scripts** to simulate real-world failures
- **Connection Monitors & alerts** to trigger the SRE Agent automatically

---

## Architecture

```
                        ┌──────────────────────┐
                        │    On-Prem VNet      │
                        │    10.100.0.0/16     │
                        │    VPN GW (BGP)      │
                        │    Test VM           │
                        └──────────┬───────────┘
                       S2S VPN     │     S2S VPN
                 ┌─────────────────┴─────────────────┐
        ┌────────┴─────────┐              ┌──────────┴────────┐
        │   Hub 1 VNet     │              │   Hub 2 VNet      │
        │   10.1.0.0/16    │              │   10.2.0.0/16     │
        │   NVA (iptables) │              │   NVA (iptables)  │
        │   VPN GW (BGP)   │              │   VPN GW (BGP)    │
        │   Internal LB    │              │   Internal LB     │
        └──┬─────────────┬─┘              └──┬─────────────┬──┘
     ┌─────┴────┐  ┌─────┴────┐         ┌────┴─────┐  ┌────┴─────┐
     │ Spoke 11 │  │ Spoke 12 │         │ Spoke 21 │  │ Spoke 22 │
     │ 10.11.   │  │ 10.12.   │         │ 10.21.   │  │ 10.22.   │
     │ 0.0/16   │  │ 0.0/16   │         │ 0.0/16   │  │ 0.0/16   │
     │ VM       │  │ VM       │         │ VM       │  │ VM       │
     └──────────┘  └──────────┘         └──────────┘  └──────────┘
```

**Key design points:**

| Component | Purpose |
|-----------|---------|
| On-Prem VNet + VPN GW | Simulates an on-premises data centre connected via two S2S VPN tunnels |
| Hub 1 / Hub 2 | Transit hubs running Linux NVA firewalls behind internal load balancers |
| Spoke VNets (×4) | Workload VNets peered to their hub, each with a test VM |
| VPN Gateways (×3) | Site-to-site VPN with BGP for dynamic route exchange |
| Connection Monitors | End-to-end reachability tests across every path |
| Azure Monitor Alerts | Fire when Connection Monitor tests fail |

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Azure subscription** | With permissions to create VNets, VPN Gateways, VMs, LBs, and Monitor resources |
| **Azure CLI** | v2.50+ — [Install](https://aka.ms/install-azure-cli) |
| **Bicep CLI** | Bundled with Azure CLI ≥ 2.20 |
| **SSH key pair** | Recommended — `ssh-keygen -t rsa -b 4096` |
| **Shell** | Bash (Linux / macOS / WSL) **or** PowerShell 7+ |

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/erjosito/networking-sre-agent.git
cd networking-sre-agent

# 2. Log in to Azure
az login

# 3. Deploy (defaults: eastus2, resource group netsre-rg)
./scripts/deploy.sh

# 4. Or customise the deployment
./scripts/deploy.sh \
    --resource-group mylab-rg \
    --location westus2 \
    --prefix mylab

# 5. Wait ~30-45 minutes (VPN Gateways are the bottleneck)

# 6. Verify connectivity
./scripts/check-health.sh --resource-group netsre-rg
```

**PowerShell:**

```powershell
.\scripts\deploy.ps1
# or
.\scripts\deploy.ps1 -ResourceGroup "mylab-rg" -Location "westus2" -Prefix "mylab"
```

---

## Fault Injection

Simulate real-world networking failures to exercise the SRE Agent's investigation capabilities.

```bash
# Inject a fault
./scripts/inject-fault.sh --fault <scenario> --resource-group netsre-rg

# Revert all active faults
./scripts/revert-all.sh --resource-group netsre-rg
```

### Available Scenarios

| Scenario | Command | Description | Expected Impact |
|----------|---------|-------------|-----------------|
| **VPN Disconnect** | `vpn-disconnect` | Resets the On-Prem ↔ Hub 1 VPN connection | On-prem cannot reach Hub 1 or its spokes |
| **NVA Failure** | `nva-stop` | Stops the NVA VM in Hub 1 | Spoke 11 / 12 lose outbound & cross-spoke connectivity |
| **NSG Block** | `nsg-block` | Adds a Deny-All inbound rule to Spoke 11's NSG | Spoke 11 VM becomes unreachable |
| **UDR Black-hole** | `udr-blackhole` | Points Spoke 11's default route to a non-existent next hop | All traffic from Spoke 11 is dropped |
| **BGP Route Manipulation** | `bgp-withdraw` | Withdraws advertised routes on Hub 1 VPN GW | On-prem loses routes to Hub 1 spokes |
| **DNS Failure** | `dns-break` | Misconfigures the custom DNS setting on Spoke 11 VNet | Name resolution fails for Spoke 11 workloads |
| **Peering Disconnect** | `peering-disconnect` | Removes VNet peering between Hub 1 and Spoke 11 | Spoke 11 is fully isolated from Hub 1 |
| **Firewall Rule Block** | `fw-block` | Adds an iptables DROP rule on the NVA in Hub 1 | Traffic transiting Hub 1 NVA is silently dropped |

### Multi-Fault Scenarios

Combine faults to create more challenging investigation scenarios:

```bash
# Simultaneous VPN + NVA failure
./scripts/inject-fault.sh --fault vpn-disconnect --resource-group netsre-rg
./scripts/inject-fault.sh --fault nva-stop       --resource-group netsre-rg

# Revert everything
./scripts/revert-all.sh --resource-group netsre-rg
```

---

## Connection Monitors

The deployment creates Connection Monitor tests that continuously verify reachability across every critical path.

### Monitored Paths

| Source | Destination | Protocol | What it validates |
|--------|-------------|----------|-------------------|
| On-Prem VM | Spoke 11 VM | ICMP + TCP 22 | End-to-end VPN → Hub → Spoke path |
| On-Prem VM | Spoke 21 VM | ICMP + TCP 22 | Cross-hub path via On-Prem → Hub 2 |
| Spoke 11 VM | Spoke 12 VM | ICMP + TCP 22 | Intra-hub spoke-to-spoke via NVA |
| Spoke 11 VM | Spoke 21 VM | ICMP + TCP 22 | Cross-hub spoke-to-spoke |
| Hub 1 NVA | Hub 2 NVA | ICMP | Hub-to-hub NVA reachability |

### Viewing Results

1. **Azure Portal** → Monitor → Connection Monitor
2. **Azure CLI:**
   ```bash
   az network watcher connection-monitor list \
       --resource-group netsre-rg \
       --output table
   ```
3. **Alerts** are auto-configured to fire when any test fails for ≥ 2 consecutive checks. These alerts integrate with the SRE Agent.

---

## Azure SRE Agent Setup

Follow these steps to connect this environment to the [Azure SRE Agent](https://sre.azure.com) (preview):

### 1. Access the SRE Agent

Navigate to **https://sre.azure.com** and sign in with your Azure AD credentials.

### 2. Connect Your Subscription

- Go to **Settings → Data Sources**
- Add your Azure subscription (requires at least **Reader** role)
- The agent will discover the networking resources automatically

### 3. Upload Knowledge Base

Upload the files from the `knowledge/` folder to the SRE Agent:

- Go to **Settings → Knowledge Base → Upload Files**
- Select all `.md` files from the `knowledge/` directory
- These documents teach the agent about Azure networking patterns and troubleshooting

### 4. Create a Custom Agent

- Go to **Agents → Create New Agent**
- Name: **Network Expert**
- Description: *Specialises in Azure hub-spoke networking, VPN, NVA, and connectivity troubleshooting*
- Attach the uploaded knowledge files
- Enable **Azure Monitor** as a data source

### 5. Connect Alerts

- Go to **Settings → Alert Integration**
- Link the Azure Monitor Action Group created by the deployment
- When a Connection Monitor test fails, the SRE Agent receives the alert and auto-investigates

### 6. Test the Flow

```bash
# Inject a fault
./scripts/inject-fault.sh --fault vpn-disconnect --resource-group netsre-rg

# The Connection Monitor will detect the failure within ~2 minutes
# The alert fires and the SRE Agent begins investigation
# Check the SRE Agent dashboard for findings and remediation suggestions

# Revert when done
./scripts/revert-all.sh --resource-group netsre-rg
```

---

## Knowledge Base Files

| File | Topics Covered |
|------|----------------|
| `knowledge/azure-networking-fundamentals.md` | VNets, subnets, NSGs, UDRs, DNS, and peering |
| `knowledge/hub-spoke-topology.md` | Hub-spoke design patterns, transit routing, shared services |
| `knowledge/vpn-expressroute-connectivity.md` | VPN Gateway, S2S/P2S, BGP, ExpressRoute, failover |
| `knowledge/network-security-nva.md` | NVA patterns, iptables, Azure Firewall, load-balanced NVAs |
| `knowledge/monitoring-troubleshooting.md` | Network Watcher, Connection Monitor, NSG flow logs, diagnostics |
| `knowledge/common-failure-scenarios.md` | Root causes, symptoms, and remediation for common networking issues |

---

## Project Structure

```
networking-sre-agent/
├── .gitignore
├── README.md
├── knowledge/                        # SRE Agent knowledge base
│   ├── azure-networking-fundamentals.md
│   ├── hub-spoke-topology.md
│   ├── vpn-expressroute-connectivity.md
│   ├── network-security-nva.md
│   ├── monitoring-troubleshooting.md
│   └── common-failure-scenarios.md
├── infra/                            # Bicep infrastructure templates
│   ├── main.bicep
│   ├── main.bicepparam
│   └── modules/
│       ├── hub.bicep
│       ├── spoke.bicep
│       ├── onprem.bicep
│       ├── vpn-connections.bicep
│       ├── connection-monitors.bicep
│       └── alerts.bicep
├── scripts/                          # Deployment & operations
│   ├── deploy.sh
│   ├── deploy.ps1
│   ├── teardown.sh
│   ├── teardown.ps1
│   ├── inject-fault.sh
│   ├── inject-fault.ps1
│   ├── revert-all.sh
│   └── check-health.sh
└── ref/                              # Reference material (not committed)
```

---

## Troubleshooting

### Deployment Failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| *"SkuNotAvailable"* | VM size not available in region | Change `--location` or use a different VM SKU |
| *"QuotaExceeded"* | Subscription vCPU quota hit | Request a quota increase or use a smaller prefix |
| Timeout after 60+ min | VPN Gateway stuck provisioning | Delete the RG and redeploy |

### VPN Gateway Status

```bash
# Check gateway connection status
az network vpn-connection list \
    --resource-group netsre-rg \
    --output table

# Check BGP peer status
az network vnet-gateway list-bgp-peer-status \
    --resource-group netsre-rg \
    --name <gateway-name> \
    --output table

# Check learned routes
az network vnet-gateway list-learned-routes \
    --resource-group netsre-rg \
    --name <gateway-name> \
    --output table
```

### Connection Monitor Not Reporting

1. Verify the Network Watcher extension is installed on all VMs:
   ```bash
   az vm extension list --resource-group netsre-rg --vm-name <vm-name> --output table
   ```
2. Check that Connection Monitor tests are in **Running** state
3. Ensure NSGs allow ICMP and TCP 22 between test endpoints

---

## Cost Considerations

> **⚠️ Tear down the environment when not in use to avoid unnecessary charges.**

| Component | Count | Est. Monthly Cost |
|-----------|-------|-------------------|
| VPN Gateways (VpnGw1) | 3 | ~$420 ($140 each) |
| VMs (Standard_B2ms) | 7 | ~$420 ($60 each) |
| Load Balancers (Standard) | 2 | ~$40 |
| Connection Monitors | 5 tests | ~$10 |
| VNet Peering / Data Transfer | — | ~$5–20 |
| **Total (24/7)** | | **~$900–1,000 / month** |

```bash
# Tear down when finished
./scripts/teardown.sh --resource-group netsre-rg

# PowerShell
.\scripts\teardown.ps1 -ResourceGroup "netsre-rg"
```

---

## License

This project is licensed under the [MIT License](LICENSE).
