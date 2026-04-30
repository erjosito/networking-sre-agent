# Azure DNS & Private Link — SRE Knowledge Base

> Audience: SRE engineers troubleshooting Azure networking.
> Scope: Azure DNS (public/private), Private Link, Private Endpoints, hybrid DNS, and failure scenarios.

---

## 1. Azure DNS Overview

Azure DNS hosts DNS zones on Azure infrastructure, providing name resolution via Microsoft's global anycast network.

### Public DNS Zones

- Host DNS records for internet-facing domains (e.g., `contoso.com`).
- Authoritative only — Azure DNS does not support domain registration.
- Name servers are assigned per zone (e.g., `ns1-01.azure-dns.com`).
- Support for all standard record types plus alias records.

### Private DNS Zones

- Provide name resolution **within** Azure virtual networks.
- Not resolvable from the public internet.
- Linked to VNets via **virtual network links**.
- Common pattern: `privatelink.<service>.core.windows.net` for Private Endpoint DNS.

### DNS Record Types

| Type  | Purpose                              | Example                          |
|-------|--------------------------------------|----------------------------------|
| A     | IPv4 address mapping                 | `app.contoso.com → 10.0.1.4`    |
| AAAA  | IPv6 address mapping                 | `app.contoso.com → 2001:db8::1` |
| CNAME | Canonical name (alias to another name)| `www → app.contoso.com`         |
| MX    | Mail exchange                        | `mail.contoso.com` priority 10  |
| TXT   | Text records (SPF, verification)     | `v=spf1 include:...`            |
| SRV   | Service locator                      | `_sip._tcp.contoso.com`         |
| NS    | Name server delegation               | Auto-created at zone apex        |
| SOA   | Start of authority                   | Auto-created at zone apex        |
| PTR   | Reverse DNS lookup                   | `4.1.0.10.in-addr.arpa`         |

### Alias Records

- Point directly to an Azure resource (Traffic Manager, CDN, public IP, or another DNS zone record).
- Track IP changes automatically — no stale records.
- Support apex (naked) domains, unlike CNAME records.
- Created by setting `targetResource` on an A, AAAA, or CNAME record set.

```bash
# Create an alias record pointing to a public IP
az network dns record-set a create -g myRG -z contoso.com -n "@" --target-resource /subscriptions/.../publicIPAddresses/myPIP
```

---

## 2. Private DNS Zones

### Virtual Network Links

Each private DNS zone must be **linked** to one or more VNets to be queryable from those VNets.

| Property            | Description                                                      |
|---------------------|------------------------------------------------------------------|
| VNet link           | Associates a VNet with a private DNS zone                        |
| Auto-registration   | When enabled, automatically creates DNS records for VMs in the VNet |
| Registration VNet   | A VNet link with auto-registration enabled (max 1 per VNet)      |
| Resolution VNet     | A VNet link without auto-registration (read-only resolution)     |

**Limits:**
- A private DNS zone can have up to **1000** virtual network links.
- A VNet can be linked to up to **1000** private DNS zones.
- A VNet can have auto-registration enabled on only **1** private DNS zone.

### Auto-Registration Behavior

- When enabled, Azure automatically creates A records for VM NICs in the linked VNet.
- Records are created using the VM hostname (not the Azure resource name).
- Forward (A) and reverse (PTR) records are managed automatically.
- Records are removed when the VM is deallocated or deleted.
- Does **not** register records for PaaS services or Private Endpoints — those use DNS zone groups.

```bash
# Create a private DNS zone
az network private-dns zone create -g myRG -n contoso.internal

# Link with auto-registration
az network private-dns link vnet create \
  -g myRG -z contoso.internal -n myLink \
  --virtual-network myVNet --registration-enabled true

# Link without auto-registration (resolution only)
az network private-dns link vnet create \
  -g myRG -z contoso.internal -n spokeLink \
  --virtual-network spokeVNet --registration-enabled false
```

### Split-Horizon DNS

Split-horizon allows the same domain name to resolve differently depending on where the query originates:

- **From internet:** `storage.contoso.com` → public IP via public DNS.
- **From VNet:** `storage.contoso.com` → private IP via private DNS zone.

Implementation:
1. Public DNS zone for `contoso.com` with public A/CNAME records.
2. Private DNS zone for `contoso.com` linked to internal VNets with private A records.
3. VNet clients query Azure-provided DNS (168.63.129.16), which checks private zones first.

---

## 3. DNS Resolution Flow

### Azure-Provided DNS (168.63.129.16)

The wireserver IP `168.63.129.16` is a virtual public IP that provides DNS resolution to all Azure VMs and services.

**Resolution order:**
1. Check private DNS zones linked to the VM's VNet.
2. If no match, forward to Azure public DNS recursive resolver.

**Key facts:**
- Available from any Azure VM without configuration.
- Used as the default DNS server unless a custom DNS server is configured on the VNet/NIC.
- Also handles DHCP, health probes, and Azure Instance Metadata.
- Must be reachable for Private Endpoint DNS to work.

### Custom DNS Servers

When a VNet or NIC is configured with custom DNS servers:

- All DNS queries from VMs go to the **custom server first**.
- The custom server must forward unresolvable queries appropriately.
- **Critical:** If the custom DNS server does not forward to `168.63.129.16`, private DNS zone resolution breaks.

```bash
# Set custom DNS on a VNet
az network vnet update -g myRG -n myVNet --dns-servers 10.0.0.4 10.0.0.5

# Verify DNS settings on a NIC
az network nic show -g myRG -n myNIC --query "dnsSettings"
```

### DNS Forwarding & Conditional Forwarding

**DNS forwarding** directs queries from one DNS server to another:
- On-premises DNS → Azure DNS Private Resolver inbound endpoint → private DNS zones.
- Azure custom DNS → `168.63.129.16` for Azure-hosted zones.

**Conditional forwarding** forwards queries for specific domains to designated servers:
- Forward `*.database.windows.net` → Azure DNS (`168.63.129.16`) for SQL Private Endpoints.
- Forward `corp.contoso.com` → on-premises DNS server for corporate resources.

---

## 4. Azure DNS Private Resolver

A fully managed DNS resolver deployed inside a VNet, replacing the need for DNS VMs (e.g., BIND, Windows DNS).

### Architecture

```
On-premises DNS ──► Inbound Endpoint (10.0.1.4) ──► Azure Private DNS Zones
                                                         │
Azure VM ──────────► Outbound Endpoint ──► Forwarding Ruleset ──► On-prem DNS
```

### Inbound Endpoints

- Provide a private IP address that external DNS servers (on-prem) can forward queries to.
- Deployed in a **dedicated subnet** (minimum /28, delegated to `Microsoft.Network/dnsResolvers`).
- Queries hitting this IP are resolved against Azure private DNS zones linked to the resolver's VNet.
- Use case: on-premises servers need to resolve `*.privatelink.blob.core.windows.net`.

```bash
# Create a DNS Private Resolver
az dns-resolver create -g myRG -n myResolver --id /subscriptions/.../virtualNetworks/hubVNet

# Create inbound endpoint
az dns-resolver inbound-endpoint create \
  -g myRG --resolver-name myResolver -n inbound \
  --ip-configurations "[{private-ip-allocation-method:Dynamic,id:/subscriptions/.../subnets/InboundSubnet}]"
```

### Outbound Endpoints

- Allow Azure VMs to forward DNS queries to external DNS servers (on-premises, third-party).
- Deployed in a **dedicated subnet** (minimum /28, delegated to `Microsoft.Network/dnsResolvers`).
- Associated with **DNS forwarding rulesets** that define conditional forwarding rules.

```bash
# Create outbound endpoint
az dns-resolver outbound-endpoint create \
  -g myRG --resolver-name myResolver -n outbound \
  --id /subscriptions/.../subnets/OutboundSubnet

# Create forwarding ruleset
az dns-resolver forwarding-ruleset create \
  -g myRG -n myRuleset \
  --outbound-endpoints "[{id:/subscriptions/.../outboundEndpoints/outbound}]"

# Add a forwarding rule for on-premises domain
az dns-resolver forwarding-rule create \
  -g myRG --ruleset-name myRuleset -n corpForward \
  --domain-name "corp.contoso.com." \
  --target-dns-servers "[{ip-address:10.1.0.4,port:53}]"
```

### DNS Forwarding Rulesets

- Contain rules that map domain names to target DNS servers.
- Linked to VNets — all VMs in linked VNets use the ruleset for matching domains.
- A VNet can be linked to **one** forwarding ruleset at a time.
- The ruleset is evaluated before Azure's default DNS resolution.

**Resolution order with DNS Private Resolver:**
1. DNS forwarding ruleset (if VNet is linked to one) — matched by longest suffix.
2. Private DNS zones linked to the VNet.
3. Azure public DNS recursive resolver.

### Hybrid DNS Resolution Patterns

| Direction            | Path                                                     |
|----------------------|----------------------------------------------------------|
| Azure → On-premises  | VM → Outbound endpoint → Forwarding ruleset → On-prem DNS |
| On-premises → Azure  | On-prem DNS → Conditional forward → Inbound endpoint → Private DNS zone |
| Spoke → Hub          | Spoke VM → Hub DNS (via VNet peering) → Private Resolver → Private DNS zone |

---

## 5. Private Link & Private Endpoints

### How Private Endpoints Work

A **Private Endpoint** is a network interface (NIC) with a private IP in your VNet that connects to an Azure PaaS service over the Microsoft backbone.

**Key components:**
- **Private Endpoint resource:** Azure resource mapped to a target PaaS service (or subresource).
- **Network interface:** An automatically created NIC with a private IP from the specified subnet.
- **Private Link connection:** The logical connection between the endpoint and the service, with approval state.

**Traffic flow:**
```
Client (10.0.1.10) ──► Private Endpoint NIC (10.0.2.5) ──► Microsoft backbone ──► PaaS service
```

- Traffic never traverses the public internet.
- The PaaS service sees the connection originating from the Private Endpoint's private IP.
- Source IP of the client is preserved (NAT is not applied within the VNet).

### NIC and IP Allocation

- The Private Endpoint NIC is placed in the subnet you specify.
- IPs are allocated from the subnet's address space (dynamic by default, static supported).
- One Private Endpoint can have **multiple IPs** if the target service has multiple subresources (e.g., SQL has `sqlServer` and `sqlOnDemand` for Synapse).
- The NIC is **read-only** — you cannot modify it directly.
- NSGs are supported on Private Endpoint subnets (requires enabling the feature on the subnet).

```bash
# Create a Private Endpoint for a storage account (blob subresource)
az network private-endpoint create \
  -g myRG -n myBlobPE \
  --vnet-name myVNet --subnet peSubnet \
  --private-connection-resource-id /subscriptions/.../storageAccounts/myStorage \
  --group-id blob \
  --connection-name myConnection

# Get the private IP assigned
az network private-endpoint show -g myRG -n myBlobPE \
  --query "customDnsConfigs[].ipAddresses" -o tsv
```

### Network Security Groups on Private Endpoints

- **Not enabled by default** — must be explicitly enabled on the subnet.
- Once enabled, NSG rules apply to Private Endpoint traffic.
- UDRs can also be applied to Private Endpoint subnets when the feature is enabled.

```bash
# Enable NSG support on Private Endpoint subnet
az network vnet subnet update \
  -g myRG --vnet-name myVNet -n peSubnet \
  --private-endpoint-network-policies Enabled
```

### Private Link Service (Custom/BYO Services)

Expose your own services (behind a Standard Load Balancer) to consumers via Private Link:

- Provider creates a **Private Link Service** mapped to a load balancer frontend.
- Consumer creates a **Private Endpoint** targeting the Private Link Service.
- Supports cross-tenant connectivity with approval workflows.
- Useful for ISVs and shared-services teams.
- NAT is applied — provider sees traffic from a NAT IP, not the consumer's IP.

---

## 6. Private Endpoint DNS

### The DNS Challenge

When you create a Private Endpoint, the PaaS service's public FQDN must resolve to the **private IP** for VNet clients, while still resolving to the public IP for internet clients.

**How Azure solves this (CNAME chain):**

```
myaccount.blob.core.windows.net
  └─ CNAME ──► myaccount.privatelink.blob.core.windows.net
                  └─ A record ──► 10.0.2.5  (in private DNS zone)
```

1. Public DNS for `myaccount.blob.core.windows.net` returns a CNAME to `myaccount.privatelink.blob.core.windows.net`.
2. If the client is in a VNet with the `privatelink.blob.core.windows.net` private DNS zone linked, the A record resolves to the private IP.
3. If the client is on the internet, `privatelink.blob.core.windows.net` resolves to the public IP via public DNS.

### Recommended Private DNS Zone Names

| Azure Service                  | Zone Name                                          |
|-------------------------------|-----------------------------------------------------|
| Blob Storage                  | `privatelink.blob.core.windows.net`                 |
| Data Lake Gen2                | `privatelink.dfs.core.windows.net`                  |
| File Storage                  | `privatelink.file.core.windows.net`                 |
| Queue Storage                 | `privatelink.queue.core.windows.net`                |
| Table Storage                 | `privatelink.table.core.windows.net`                |
| Web (Static Website)          | `privatelink.web.core.windows.net`                  |
| Azure SQL Database            | `privatelink.database.windows.net`                  |
| Azure Cosmos DB (SQL API)     | `privatelink.documents.azure.com`                   |
| Azure Key Vault               | `privatelink.vaultcore.azure.net`                   |
| Azure Container Registry      | `privatelink.azurecr.io`                            |
| Azure Event Hubs              | `privatelink.servicebus.windows.net`                |
| Azure Service Bus             | `privatelink.servicebus.windows.net`                |
| Azure Monitor / Log Analytics | `privatelink.monitor.azure.com`                     |
| Azure App Configuration       | `privatelink.azconfig.io`                           |
| Azure Cognitive Services      | `privatelink.cognitiveservices.azure.com`            |
| Azure OpenAI                  | `privatelink.openai.azure.com`                      |
| Azure Kubernetes Service (API)| `privatelink.<region>.azmk8s.io`                    |
| Azure App Service / Functions | `privatelink.azurewebsites.net`                     |
| Azure Database for PostgreSQL | `privatelink.postgres.database.azure.com`            |
| Azure Database for MySQL      | `privatelink.mysql.database.azure.com`               |
| Azure Redis Cache             | `privatelink.redis.cache.windows.net`                |
| Azure SignalR                 | `privatelink.service.signalr.net`                    |

### DNS Zone Groups

DNS zone groups automatically manage DNS records for Private Endpoints:

- When a Private Endpoint is associated with a DNS zone group, an A record is **automatically created** in the linked private DNS zone.
- When the Private Endpoint is deleted, the A record is **automatically removed**.
- Eliminates manual DNS record management.
- Recommended approach for all Private Endpoints.

```bash
# Create a DNS zone group for a Private Endpoint
az network private-endpoint dns-zone-group create \
  -g myRG --endpoint-name myBlobPE -n default \
  --private-dns-zone /subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net \
  --zone-name blob
```

---

## 7. Hub-Spoke DNS Architecture

### Centralized DNS Design

```
                    ┌──────────────────────────────────────┐
                    │           Hub VNet (10.0.0.0/16)      │
                    │                                       │
  On-premises ◄───► │  DNS Private Resolver                 │
                    │    ├─ Inbound Endpoint (10.0.1.4)     │
                    │    └─ Outbound Endpoint (10.0.2.4)    │
                    │                                       │
                    │  Private DNS Zones (linked to Hub):   │
                    │    ├─ privatelink.blob.core.windows.net│
                    │    ├─ privatelink.database.windows.net │
                    │    └─ privatelink.web.core.windows.net │
                    └──────────────┬────────────────────────┘
                                   │ VNet Peering
                    ┌──────────────┴────────────────────────┐
                    │         Spoke VNet (10.1.0.0/16)       │
                    │  DNS: Hub DNS / 168.63.129.16          │
                    │  Private Endpoints deployed here       │
                    └────────────────────────────────────────┘
```

### Key Design Principles

1. **Private DNS zones linked to Hub VNet** — all zones are linked to the hub (resolution link). Spoke VNets resolve via peering + hub DNS.
2. **DNS forwarding rulesets linked to Spoke VNets** — spoke VMs use the DNS Private Resolver in the hub via ruleset VNet links.
3. **On-premises conditional forwarding** — on-prem DNS forwards `privatelink.*` domains to the inbound endpoint IP in the hub.
4. **Single source of truth** — avoid creating duplicate private DNS zones per spoke.

### Spoke VNet DNS Configuration Options

| Option                               | How It Works                                                      |
|--------------------------------------|-------------------------------------------------------------------|
| VNet DNS → Hub DNS server IP         | Spoke VNet custom DNS set to hub DNS resolver/VM IP               |
| Forwarding ruleset VNet link         | Link spoke VNet to the hub's DNS forwarding ruleset               |
| Private DNS zone VNet link           | Link each private DNS zone to each spoke VNet (works but doesn't scale) |

**Recommended:** Use DNS forwarding ruleset VNet links for spokes. This avoids linking every private DNS zone to every spoke VNet individually.

### On-Premises DNS Integration

For on-premises clients to resolve Private Endpoint FQDNs:

1. Configure **conditional forwarders** on the on-premises DNS server for each `privatelink.*` domain.
2. Forward to the **inbound endpoint IP** of the DNS Private Resolver in the hub.
3. The inbound endpoint resolves against private DNS zones linked to the hub VNet.

```powershell
# Example: Windows DNS Server conditional forwarder
Add-DnsServerConditionalForwarderZone `
  -Name "privatelink.blob.core.windows.net" `
  -MasterServers 10.0.1.4 `
  -ReplicationScope "Forest"
```

---

## 8. Common Failure Scenarios

### 8.1 Private Endpoint Resolving to Public IP

**Symptom:** `nslookup myaccount.blob.core.windows.net` returns a public IP instead of the Private Endpoint's private IP.

**Root causes:**
- Private DNS zone `privatelink.blob.core.windows.net` does not exist.
- The private DNS zone exists but is **not linked** to the VNet where the client resides.
- The A record for the service was not created (DNS zone group missing or misconfigured).
- The VNet is using a custom DNS server that does not forward to `168.63.129.16`.

**Fix:**
```bash
# Verify DNS zone exists
az network private-dns zone show -g myRG -n privatelink.blob.core.windows.net

# Verify VNet link exists
az network private-dns link vnet list -g myRG -z privatelink.blob.core.windows.net -o table

# Verify A record exists
az network private-dns record-set a list -g myRG -z privatelink.blob.core.windows.net -o table

# Verify DNS zone group on the Private Endpoint
az network private-endpoint dns-zone-group list -g myRG --endpoint-name myBlobPE -o table
```

### 8.2 DNS Resolution Failures from On-Premises

**Symptom:** On-premises clients cannot resolve Private Endpoint FQDNs — get NXDOMAIN or public IP.

**Root causes:**
- No conditional forwarder configured on the on-premises DNS server.
- Conditional forwarder points to the wrong IP (should be the inbound endpoint IP).
- VPN/ExpressRoute connectivity issue preventing DNS traffic to the hub.
- Inbound endpoint subnet NSG blocking UDP/TCP port 53.

**Fix:**
```bash
# Verify inbound endpoint is reachable from on-prem (from an on-prem machine)
nslookup myaccount.blob.core.windows.net 10.0.1.4

# Check inbound endpoint health
az dns-resolver inbound-endpoint show -g myRG --resolver-name myResolver -n inbound
```

### 8.3 Stale DNS Records After Private Endpoint Recreation

**Symptom:** After deleting and recreating a Private Endpoint, the DNS record still points to the old IP.

**Root causes:**
- DNS zone group was not configured — records were created manually and not cleaned up.
- DNS TTL caching on client machines or intermediate DNS servers.
- The old Private Endpoint was deleted but the DNS zone group or A record was not cleaned up.

**Fix:**
```bash
# List A records and check for stale entries
az network private-dns record-set a list -g myRG -z privatelink.blob.core.windows.net -o table

# Delete stale record
az network private-dns record-set a delete -g myRG -z privatelink.blob.core.windows.net -n myaccount

# Flush DNS cache on Windows client
ipconfig /flushdns

# Flush DNS cache on Linux client
sudo systemd-resolve --flush-caches
```

### 8.4 Split-Horizon DNS Conflicts

**Symptom:** Internal clients resolve the wrong IP, or external clients get internal IPs.

**Root causes:**
- Private DNS zone for the full domain (e.g., `contoso.com`) overrides all public records for VNet clients.
- Missing records in the private zone — private zone takes precedence but lacks the needed entry, resulting in NXDOMAIN.

**Fix:** Only create private DNS zone records for specific hostnames needed internally. Avoid creating a blanket private zone for the same domain as your public DNS unless you replicate all needed records.

### 8.5 Auto-Registration Not Working

**Symptom:** VMs in a linked VNet do not get DNS records in the private DNS zone.

**Root causes:**
- VNet link exists but `registration-enabled` is `false`.
- The VNet already has auto-registration enabled with a **different** private DNS zone (limit: 1 registration zone per VNet).
- The VM was created before the VNet link was established (existing VMs are registered eventually, but there can be a delay).

**Fix:**
```bash
# Check if registration is enabled on the VNet link
az network private-dns link vnet show -g myRG -z contoso.internal -n myLink \
  --query "registrationEnabled"

# Update to enable registration
az network private-dns link vnet update -g myRG -z contoso.internal -n myLink \
  --registration-enabled true
```

### 8.6 Custom DNS Server Not Forwarding to 168.63.129.16

**Symptom:** VMs using a custom DNS server cannot resolve Private Endpoint FQDNs or Azure-internal names.

**Root causes:**
- Custom DNS server (e.g., Windows DNS, BIND) does not have a forwarder configured to `168.63.129.16`.
- Firewall rules on the custom DNS server blocking outbound DNS to `168.63.129.16`.
- The custom DNS server is in a different VNet without peering or line of sight to Azure DNS.

**Fix:** Configure the custom DNS server to forward unresolved queries to `168.63.129.16`:

```powershell
# Windows DNS Server — set forwarder
Set-DnsServerForwarder -IPAddress "168.63.129.16"

# BIND — named.conf forwarders
# forwarders { 168.63.129.16; };
```

### 8.7 Private Endpoint in Different Region Than DNS Zone VNet Link

**Symptom:** Private Endpoint works locally but not from VNets in other regions.

**Root cause:** The private DNS zone is linked only to VNets in one region. VNets in other regions do not have links.

**Key fact:** Private DNS zones are **global** resources — they are not tied to a region. But each VNet that needs to resolve records must have a VNet link. Cross-region resolution works as long as the VNet link exists and network connectivity (peering) is in place.

**Fix:** Add VNet links for all VNets that need resolution, regardless of region.

### 8.8 NSG/UDR Blocking Traffic to Private Endpoint

**Symptom:** DNS resolves correctly to the private IP, but connections to the Private Endpoint time out.

**Root causes:**
- NSG on the client subnet blocking outbound traffic to the Private Endpoint IP.
- NSG on the Private Endpoint subnet blocking inbound traffic (only if NSG enforcement is enabled).
- UDR forcing traffic through an NVA/firewall that does not have a route to the Private Endpoint subnet.
- UDR with a `0.0.0.0/0` next-hop to an NVA that drops or misroutes the traffic.

**Diagnosis:**
```bash
# Check effective routes on the client VM NIC
az network nic show-effective-route-table -g myRG -n clientNIC -o table

# Check effective NSG rules
az network nic list-effective-nsg -g myRG -n clientNIC

# Use Network Watcher next-hop check
az network watcher show-next-hop \
  -g myRG --vm clientVM \
  --source-ip 10.1.0.4 --dest-ip 10.0.2.5
```

### 8.9 Multiple Private DNS Zones for Same Service

**Symptom:** Inconsistent DNS resolution — some VNets resolve the correct private IP, others don't.

**Root causes:**
- Multiple private DNS zones with the same name (e.g., `privatelink.blob.core.windows.net`) in different resource groups or subscriptions.
- Different VNets linked to different copies of the zone, with inconsistent A records.
- DNS zone groups on Private Endpoints registered in the wrong zone.

**Fix:** Consolidate to a **single** private DNS zone per service across the organization. Use Azure Policy to enforce this.

### 8.10 DNS TTL Caching Causing Delayed Failover

**Symptom:** After updating a DNS record (e.g., failover scenario), clients still connect to the old IP.

**Root causes:**
- DNS TTL on the record set is too high (default is 3600 seconds / 1 hour for private DNS zones).
- Client OS DNS cache holding stale entries.
- Intermediate DNS servers (custom DNS, on-prem) caching the old response.

**Fix:**
```bash
# Set lower TTL on critical records (e.g., 60 seconds)
az network private-dns record-set a update \
  -g myRG -z contoso.internal -n app --set ttl=60

# Verify current TTL
az network private-dns record-set a show \
  -g myRG -z contoso.internal -n app --query "ttl"
```

---

## 9. Troubleshooting Toolkit

### DNS Query Commands

```bash
# Basic resolution test (Windows)
nslookup myaccount.blob.core.windows.net

# Query a specific DNS server
nslookup myaccount.blob.core.windows.net 168.63.129.16

# Trace CNAME chain (Linux)
dig +trace myaccount.blob.core.windows.net

# Query for the CNAME to see the privatelink redirect
dig myaccount.blob.core.windows.net CNAME +short

# Resolve against Azure DNS directly
dig @168.63.129.16 myaccount.privatelink.blob.core.windows.net A +short

# Check from inside a VM for full resolution path
nslookup -debug myaccount.blob.core.windows.net

# Reverse DNS lookup
nslookup 10.0.2.5
dig -x 10.0.2.5

# PowerShell DNS resolution
Resolve-DnsName -Name myaccount.blob.core.windows.net -Type A -DnsOnly
Resolve-DnsName -Name myaccount.blob.core.windows.net -Server 168.63.129.16
```

### Verify Private Endpoint Configuration

```bash
# Show Private Endpoint details and IP
az network private-endpoint show -g myRG -n myBlobPE \
  --query "{name:name, subnet:subnet.id, ips:customDnsConfigs[].ipAddresses, status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}"

# List all Private Endpoints in a subscription
az network private-endpoint list --query "[].{name:name, rg:resourceGroup, ip:customDnsConfigs[0].ipAddresses[0]}" -o table

# Show Private Endpoint NIC effective routes
PE_NIC=$(az network private-endpoint show -g myRG -n myBlobPE --query "networkInterfaces[0].id" -o tsv)
az network nic show-effective-route-table --ids $PE_NIC -o table
```

### DNS Zone & Record Verification

```bash
# List all private DNS zones
az network private-dns zone list -o table

# List VNet links for a zone
az network private-dns link vnet list -g myRG -z privatelink.blob.core.windows.net -o table

# List all A records in a zone
az network private-dns record-set a list -g myRG -z privatelink.blob.core.windows.net -o table

# Check DNS zone group status
az network private-endpoint dns-zone-group show \
  -g myRG --endpoint-name myBlobPE -n default
```

### Network Watcher DNS Diagnostics

```bash
# Verify connectivity from VM to Private Endpoint
az network watcher test-connectivity \
  --source-resource clientVM -g myRG \
  --dest-address 10.0.2.5 --dest-port 443

# Check next hop for traffic to Private Endpoint IP
az network watcher show-next-hop \
  -g myRG --vm clientVM \
  --source-ip 10.1.0.4 --dest-ip 10.0.2.5
```

### KQL: Query DNS Logs (if Azure DNS Analytics is enabled)

```kusto
// DNS queries for a specific FQDN from Azure Firewall DNS Proxy logs
AzureDiagnostics
| where Category == "AzureFirewallDnsProxy"
| where msg_s contains "myaccount.blob.core.windows.net"
| project TimeGenerated, msg_s
| order by TimeGenerated desc
| take 50

// DNS resolution failures from VNet DNS query logs
DnsEvents
| where Name contains "privatelink"
| where ResultCode != 0
| summarize FailureCount=count() by Name, ResultCode, ClientIP, bin(TimeGenerated, 5m)
| order by FailureCount desc

// Private Endpoint connection events from Activity Log
AzureActivity
| where OperationNameValue contains "privateEndpoints"
| where ActivityStatusValue == "Failed"
| project TimeGenerated, OperationNameValue, Properties
| order by TimeGenerated desc
```

---

## 10. Best Practices

### Centralized Private DNS Zone Management

- Maintain **one private DNS zone per service type** in a central resource group (e.g., `rg-dns-zones`).
- Use Azure Policy to prevent teams from creating duplicate private DNS zones.
- Assign DNS zone management to a dedicated platform/networking team.
- Use Terraform/Bicep modules to consistently deploy and link zones.

### Naming & Organization

- Use a dedicated resource group for all `privatelink.*` DNS zones.
- Tag zones with `environment`, `owner`, and `managed-by` labels.
- Document which services use which private DNS zones.

### Hub-Spoke DNS Patterns

- Deploy DNS Private Resolver in the hub VNet.
- Link all private DNS zones to the hub VNet.
- Link forwarding rulesets to spoke VNets (avoids per-zone per-spoke linking).
- Size inbound/outbound subnets appropriately (minimum /28 each).
- Use conditional forwarders on-premises for all `privatelink.*` domains.

### DNS Zone Automation

```bash
# Example: Automate Private Endpoint DNS with zone group (Bicep snippet concept)
# When creating a Private Endpoint, always include a DNS zone group:
az network private-endpoint dns-zone-group create \
  -g myRG --endpoint-name $PE_NAME -n default \
  --private-dns-zone $DNS_ZONE_ID \
  --zone-name $ZONE_NAME

# Azure Policy: Deny Private Endpoints without DNS zone groups
# Policy definition: Microsoft.Network/privateEndpoints must have
# a child resource of type Microsoft.Network/privateEndpoints/privateDnsZoneGroups
```

### Operational Checklist

- [ ] All `privatelink.*` DNS zones exist in the central resource group.
- [ ] Each zone is linked to the hub VNet (resolution link).
- [ ] Forwarding rulesets are linked to all spoke VNets.
- [ ] On-premises DNS has conditional forwarders for all `privatelink.*` domains pointing to the inbound endpoint.
- [ ] DNS zone groups are configured on all Private Endpoints (no manual A records).
- [ ] NSG enforcement on Private Endpoint subnets is configured per policy.
- [ ] DNS TTLs are appropriate for failover requirements.
- [ ] Azure Policy enforces single-zone-per-service and mandatory DNS zone groups.
- [ ] Monitoring/alerting is configured for DNS resolution failures.

### Monitoring

- Enable **DNS Analytics** in Azure Monitor for query logging.
- Set up alerts on DNS resolution failures (ResultCode != 0).
- Monitor Private Endpoint connection state via Azure Resource Health.
- Use **Connection Monitor** (Network Watcher) for end-to-end connectivity checks to Private Endpoints.

---

## Quick Reference: End-to-End Verification

When a Private Endpoint is not working, run through this sequence:

```bash
# 1. Verify DNS resolves to private IP
nslookup myaccount.blob.core.windows.net

# 2. Verify CNAME chain includes privatelink
nslookup -type=CNAME myaccount.blob.core.windows.net

# 3. Verify Private Endpoint IP matches DNS result
az network private-endpoint show -g myRG -n myBlobPE \
  --query "customDnsConfigs[].ipAddresses" -o tsv

# 4. Verify private DNS zone has the A record
az network private-dns record-set a show \
  -g myRG -z privatelink.blob.core.windows.net -n myaccount

# 5. Verify VNet link exists for the client's VNet
az network private-dns link vnet list \
  -g myRG -z privatelink.blob.core.windows.net -o table

# 6. Verify connectivity from client to Private Endpoint IP
az network watcher test-connectivity \
  --source-resource clientVM -g myRG \
  --dest-address 10.0.2.5 --dest-port 443

# 7. Check effective routes and NSGs on client NIC
az network nic show-effective-route-table -g myRG -n clientNIC -o table
az network nic list-effective-nsg -g myRG -n clientNIC
```

If steps 1-2 return a public IP → DNS issue (sections 8.1, 8.6).
If step 3 IP doesn't match → stale DNS (section 8.3).
If step 5 shows no link → missing VNet link (section 8.1).
If step 6 fails → network issue (section 8.8).
