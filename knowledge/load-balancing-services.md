# Azure Load Balancing Services - SRE Knowledge Base

## Overview

Azure provides multiple load balancing services operating at different layers and scopes. Choosing the right service — and understanding how each fails — is critical for SRE incident response. This document covers all Azure-native load balancing options, common failure scenarios, and troubleshooting procedures.

## Decision Tree: Choosing the Right Load Balancer

### Step 1: Global vs Regional

| Requirement | Service |
|---|---|
| Global (multi-region) + HTTP/HTTPS | **Azure Front Door** |
| Global (multi-region) + Non-HTTP (TCP/UDP) | **Cross-Region Load Balancer** |
| Global (DNS-based) + Any protocol | **Traffic Manager** |
| Regional + HTTP/HTTPS | **Application Gateway** |
| Regional + Non-HTTP (TCP/UDP) | **Azure Load Balancer** |

### Step 2: Key Decision Factors

- **HTTP vs Non-HTTP**: Application Gateway and Front Door understand HTTP (L7 — URL routing, cookies, headers). Load Balancer operates at L4 (TCP/UDP only).
- **Internal vs External**: Load Balancer and Application Gateway support both internal and public-facing. Front Door is always public-facing (but can use Private Link to reach private backends). Traffic Manager is DNS-based and always external.
- **WAF Requirement**: Application Gateway WAF v2 or Front Door WAF. Load Balancer and Traffic Manager have no WAF.
- **SSL Offload**: Application Gateway and Front Door terminate SSL. Load Balancer does TCP pass-through.
- **Sticky Sessions**: Application Gateway (cookie-based affinity), Load Balancer (source IP affinity). Traffic Manager has no session affinity (DNS-based).

### Quick Reference Matrix

| Feature | Load Balancer | App Gateway | Traffic Manager | Front Door | Cross-Region LB |
|---|---|---|---|---|---|
| Layer | L4 | L7 | DNS | L7 | L4 |
| Scope | Regional | Regional | Global | Global | Global |
| Protocol | TCP/UDP | HTTP/HTTPS | Any | HTTP/HTTPS | TCP/UDP |
| Internal | Yes | Yes | No | No (Private Link origins) | No |
| WAF | No | Yes (v2) | No | Yes | No |
| SSL Offload | No | Yes | No | Yes | No |
| Health Probes | TCP/HTTP/HTTPS | HTTP/HTTPS | HTTP/HTTPS/TCP | HTTP/HTTPS | TCP/HTTP/HTTPS |

---

## Azure Load Balancer (Layer 4)

### Standard vs Basic SKU

- **Always use Standard SKU** — Basic is deprecated for new deployments and will retire September 2025
- Standard is zone-aware, supports HA ports, has SLA (99.99%), and supports cross-VNet backends
- Basic has no SLA, no zone redundancy, no HA ports, limited to single availability set backends
- You **cannot mix** Standard and Basic resources (LB, Public IP, VMs must match SKU)

### Architecture

- **Public Load Balancer**: Frontend is a public IP; distributes internet-inbound traffic to backend VMs
- **Internal Load Balancer (ILB)**: Frontend is a private IP in a VNet subnet; distributes internal traffic
- A single VM can be in backends of both public and internal LBs simultaneously

### Health Probes

- **TCP Probe**: Opens a TCP connection to the backend port — if the handshake completes, the probe succeeds
- **HTTP Probe**: Sends HTTP GET to a path — expects HTTP 200 response within the timeout
- **HTTPS Probe**: Same as HTTP but over TLS — does NOT validate the backend certificate
- Probe interval: minimum 5 seconds, default 15 seconds
- Unhealthy threshold: number of consecutive failures before marking backend as down (default 2)
- **Critical**: The probe source IP is always **168.63.129.16** — NSGs on the backend must allow this

```bash
# Check health probe status via metrics
az monitor metrics list \
  --resource "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/loadBalancers/{lb}" \
  --metric "DipAvailability" \
  --interval PT1M \
  --aggregation Average
```

### HA Ports (High Availability Ports)

- Only available on **Internal** Standard Load Balancer
- Single rule matches **all TCP and UDP ports** — used for NVA deployments
- Eliminates the need for one rule per port
- **Conflict**: You cannot have HA ports rule AND individual port rules on the same frontend IP
- Commonly used with NVAs (firewalls) where all traffic must pass through

### Outbound Rules and SNAT

- **SNAT (Source Network Address Translation)**: When backend VMs initiate outbound connections through a public LB, the source IP is translated to the LB frontend IP
- **SNAT port allocation**: Each frontend IP provides ~64,000 ports, divided among backend pool members
- **SNAT exhaustion** occurs when all allocated ports are in use — new outbound connections fail
- **Default outbound access** is deprecated — use explicit outbound rules or NAT Gateway

```bash
# Check SNAT port usage
az monitor metrics list \
  --resource "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/loadBalancers/{lb}" \
  --metric "SnatConnectionCount" \
  --interval PT1M \
  --aggregation Total \
  --filter "ConnectionState eq 'Failed'"
```

**SNAT Mitigation Strategies (priority order):**
1. **NAT Gateway** on the backend subnet — preferred, provides 64,000 ports per public IP per backend, automatic port management
2. **Multiple frontend IPs** on the outbound rule — each IP adds ~64,000 ports
3. **Increase SNAT port allocation** per backend instance in outbound rules
4. **Connection pooling** in application code — reuse TCP connections, use HTTP keep-alive
5. **Reduce idle timeout** — default is 4 minutes, lowering it frees ports faster

### Floating IP (Direct Server Return / DSR)

- When enabled, the LB does NOT rewrite the destination IP — the VM receives traffic with the frontend IP as destination
- The VM must have the frontend IP configured on a loopback interface or secondary IP
- Used for SQL Always On, specific NVA scenarios, and when the backend needs to know the original destination IP
- **Common misconfiguration**: Floating IP enabled on the rule but the loopback interface not configured on the backend VM — traffic is silently dropped

### Session Persistence (Distribution Mode)

- **None (default)**: 5-tuple hash (src IP, src port, dst IP, dst port, protocol)
- **Client IP**: 2-tuple hash (src IP, dst IP) — same client always hits same backend
- **Client IP and Protocol**: 3-tuple hash (src IP, dst IP, protocol)

---

## Application Gateway (Layer 7)

### SKU and Sizing

- **Always use v2 SKU** — v1 is deprecated
- v2 supports autoscaling (0 to 125 instances), zone redundancy, static VIP, improved performance
- **Dedicated subnet required**: Application Gateway must have its own subnet
- **Subnet sizing**: Minimum /26 recommended; /27 is the absolute minimum for v2 with autoscaling — too small causes scale-out failures
- The subnet should have **no other resources** (only other AppGWs allowed)
- **NSG on AppGW subnet** must allow:
  - Inbound: Client traffic (80/443), Health probes from `GatewayManager` service tag on ports `65200-65535`
  - Outbound: Traffic to backends, traffic to `AzureMonitor` for diagnostics

```bash
# Check Application Gateway health
az network application-gateway show-backend-health \
  --resource-group <rg> \
  --name <appgw> \
  --query 'backendAddressPoolsHealth[].backendHttpSettingsCollection[].servers[]'
```

### WAF v2

- Web Application Firewall integrated into Application Gateway
- OWASP Core Rule Set (CRS) 3.2, 3.1, or DRS 2.1
- **Detection mode**: Logs threats but does not block — use for initial tuning
- **Prevention mode**: Blocks matching requests — returns 403
- Custom rules: Rate limiting, geo-filtering, IP allow/deny lists
- WAF adds latency (typically 2-5ms) — factor into timeout calculations
- Per-site WAF policies allow different rules per listener

### Routing Capabilities

**URL-Based Routing:**
- Route based on URL path: `/images/*` → image backend pool, `/api/*` → API backend pool
- Path-based rules evaluated in order — first match wins
- Default backend pool handles unmatched paths

**Multi-Site Hosting:**
- Multiple listeners on the same port, differentiated by hostname
- Each listener can have its own SSL certificate and routing rules
- Wildcard hostnames supported (e.g., `*.contoso.com`)
- **Common issue**: Missing hostname on the listener causes all traffic to match the first listener

**Rewrites:**
- Modify request/response headers and URL path/query string
- Can strip/add headers, change host header (important for backend routing)
- Condition-based: Apply rewrites only when conditions match
- **Important**: URL rewrite happens AFTER path-based routing evaluation

**Redirects:**
- HTTP-to-HTTPS redirect (most common)
- External redirects (301/302) to any URL
- Redirect between listeners

### SSL/TLS

**SSL Termination (Offloading):**
- AppGW decrypts at the frontend, sends plaintext HTTP to backends
- Certificate stored in AppGW or referenced from Key Vault (recommended)
- Reduces CPU load on backends

**End-to-End SSL (E2E):**
- AppGW decrypts, inspects (WAF), re-encrypts, sends HTTPS to backend
- Backend certificate must be trusted — upload root CA cert to AppGW trusted root store
- **Common 502 cause**: Backend certificate not trusted by AppGW, or backend cert CN mismatch

**TLS Policy:**
- Predefined policies control minimum TLS version and cipher suites
- Use `AppGwSslPolicy20220101` or newer for TLS 1.2 minimum

### Health Probes

- **Default probe**: If no custom probe defined, AppGW sends probe to `http://127.0.0.1:<backend-port>/` — this almost never works correctly
- **Always define custom probes** with appropriate path (e.g., `/health`), hostname, and interval
- Probe hostname: Should match the hostname expected by the backend (especially with multi-site backends)
- Unhealthy threshold: default 3 consecutive failures
- Pick interval: minimum 1 second on v2
- The probe expects HTTP 200-399 as healthy — configure custom match conditions if needed

### Connection Draining

- When a backend is removed or marked unhealthy, existing connections are allowed to complete
- Configurable timeout (1-3600 seconds)
- **Must be enabled** to avoid dropped connections during deployments or scale-in events

### Key Limits

- Max 100 backend pools, 100 listeners, 100 rules per AppGW
- Max request timeout: 86400 seconds (24 hours) — but the default is 20 seconds
- Max request body size for WAF: 128 KB (default) up to 2 MB

---

## Traffic Manager (DNS-Based Global Load Balancing)

### How It Works

- Traffic Manager is a **DNS-based** load balancer — it does NOT proxy traffic
- Clients query DNS, get the IP of the chosen endpoint, and connect directly
- **Consequence**: Traffic Manager cannot see HTTP headers, paths, or payload — it's protocol-agnostic
- DNS TTL controls how fast clients switch endpoints (default 60s, minimum 0s)
- Low TTL = faster failover, but more DNS queries

### Routing Methods

| Method | Use Case | Behavior |
|---|---|---|
| **Priority** | Active/passive failover | Routes to highest-priority healthy endpoint |
| **Weighted** | A/B testing, gradual migration | Distributes traffic by weight (1-1000) |
| **Performance** | Latency-sensitive apps | Routes to closest endpoint by network latency |
| **Geographic** | Data sovereignty, regional content | Routes based on geographic origin of DNS query |
| **Multivalue** | Multiple healthy IPs returned | Returns multiple healthy endpoint IPs in DNS response |
| **Subnet** | Per-client routing | Routes based on client IP subnet ranges |

### Nested Profiles

- A Traffic Manager profile can have another profile as an endpoint
- Used to combine routing methods: e.g., Geographic (outer) → Performance (inner)
- **MinChildEndpoints**: Minimum healthy endpoints in child profile before the nested endpoint is considered degraded
- **Common misconfiguration**: MinChildEndpoints set too high — causes unnecessary failover

### Endpoint Monitoring

- Traffic Manager probes endpoints via HTTP/HTTPS/TCP
- Probe interval: 30 seconds (standard) or 10 seconds (fast)
- Tolerated failures: 3 (standard) or 1 (fast) — then endpoint marked **Degraded**
- Expected status code range: 200-299 (or custom ranges)
- Can probe a specific path (e.g., `/health`)

```bash
# Check endpoint status
az network traffic-manager endpoint show \
  --resource-group <rg> \
  --profile-name <profile> \
  --name <endpoint> \
  --type azureEndpoints \
  --query '{status:endpointStatus, monitorStatus:endpointMonitorStatus}'
```

### Key Limitations

- DNS-based — client-side DNS caching can delay failover (even with low TTL)
- No support for session affinity
- Cannot route by URL path or HTTP headers
- External clients only — no internal (VNet) endpoints without workaround

---

## Azure Front Door (Global L7 — Brief Overview)

> **For deep dive, see `azure-front-door.md`**

### Core Capabilities

- Global HTTP/HTTPS load balancing with anycast
- Integrated WAF (DDoS protection + OWASP rules)
- SSL offloading at the edge, with managed certificates
- Caching at edge PoPs — reduces load on origin
- URL-based routing across global backends
- Private Link origins — connect to private backends without exposing them to the internet

### When to Use Front Door vs Application Gateway

- **Front Door**: Multi-region web apps, global users, need edge caching or global WAF
- **Application Gateway**: Single-region, need integration with VNet, internal-facing web apps
- **Common pattern**: Front Door → Application Gateway → Backend VMs (global → regional)

---

## Cross-Region Load Balancer (Global L4)

### Architecture

- Global Standard Load Balancer tier that load balances across regional Standard Load Balancers
- Operates at Layer 4 (TCP/UDP) — for non-HTTP global load balancing
- Uses anycast to attract traffic to the nearest region
- **Backend pool members are regional Load Balancers** (not individual VMs)

### Key Characteristics

- Ultra-low latency global failover (no DNS TTL dependency)
- Health probes monitor regional LBs — unhealthy regions are drained
- Supports HA ports for NVA global deployments
- **Limitation**: Both the global and regional LBs must be Standard SKU
- **Limitation**: Floating IP must match between global and regional rules

### Use Cases

- Non-HTTP global load balancing (gaming, IoT, real-time protocols)
- Faster failover than Traffic Manager (not DNS-dependent)
- Global NVA deployments

---

## Common Failure Scenarios

### Scenario 1: Load Balancer Health Probe Failures

- **Symptoms**: Backend VMs not receiving traffic, LB metrics show DipAvailability at 0%
- **Root Causes**:
  - Application not listening on the probed port
  - NSG on backend VM NIC or subnet blocking probe source IP `168.63.129.16`
  - Windows Firewall or iptables on VM blocking the probe port
  - HTTP probe path returning non-200 status code
  - Probe targeting wrong port (e.g., 80 when app runs on 8080)
- **Detection**:
  ```bash
  # Check DipAvailability (backend health) metric
  az monitor metrics list --resource <lb-resource-id> \
    --metric "DipAvailability" --interval PT1M --aggregation Average

  # Check NSG effective rules on backend NIC
  az network nic list-effective-nsg --resource-group <rg> --name <nic>
  ```
- **Resolution**: Ensure NSG allows inbound from `168.63.129.16` on probe port; verify application is listening; check probe configuration matches application

### Scenario 2: SNAT Port Exhaustion

- **Symptoms**: Intermittent outbound connection failures from backend VMs, `SnatConnectionCount` metric with `Failed` state increasing
- **Root Causes**:
  - Too many outbound connections from too few VMs behind a public LB
  - Short-lived connections creating port churn (each port needs 4-minute TCP TIME_WAIT)
  - Application not using connection pooling
  - Backend pool grew without adjusting SNAT port allocation
- **Detection**:
  ```bash
  az monitor metrics list --resource <lb-resource-id> \
    --metric "SnatConnectionCount" --interval PT1M \
    --aggregation Total --filter "ConnectionState eq 'Failed'"

  az monitor metrics list --resource <lb-resource-id> \
    --metric "UsedSnatPorts" --interval PT1M --aggregation Average
  ```
- **Resolution**: Add NAT Gateway to subnet (preferred), add more frontend IPs, increase per-instance allocation, implement connection pooling in application code

### Scenario 3: Application Gateway 502 Bad Gateway

- **Symptoms**: Clients receive HTTP 502 from Application Gateway
- **Root Causes**:
  - All backend pool members are unhealthy (probe failure)
  - Backend returning invalid HTTP response
  - Backend SSL certificate not trusted by AppGW (E2E SSL)
  - NSG on backend or AppGW subnet blocking traffic
  - Backend pool is empty (no targets configured)
  - Connection timeout to backend (backend unreachable)
- **Detection**:
  ```bash
  # Show backend health
  az network application-gateway show-backend-health \
    --resource-group <rg> --name <appgw>

  # Check access logs (KQL in Log Analytics)
  ```
  ```kusto
  AzureDiagnostics
  | where ResourceType == "APPLICATIONGATEWAYS"
  | where httpStatus_d == 502
  | project TimeGenerated, requestUri_s, serverRouted_s, serverStatus_d, timeTaken_d
  | order by TimeGenerated desc
  | take 50
  ```
- **Resolution**: Fix backend health probes, verify NSG rules allow AppGW subnet → backend subnet on backend port, upload trusted root cert for E2E SSL

### Scenario 4: Application Gateway 504 Gateway Timeout

- **Symptoms**: Clients receive HTTP 504 from Application Gateway
- **Root Causes**:
  - Backend response time exceeds AppGW request timeout (default 20 seconds)
  - Backend is reachable but processing slowly
  - DNS resolution delay when backend pool uses FQDNs
  - Network latency between AppGW and backend (different regions or heavy NSG processing)
- **Detection**:
  ```kusto
  AzureDiagnostics
  | where ResourceType == "APPLICATIONGATEWAYS"
  | where httpStatus_d == 504
  | project TimeGenerated, requestUri_s, timeTaken_d, serverRouted_s
  | order by TimeGenerated desc
  ```
- **Resolution**: Increase request timeout in HTTP settings; optimize backend response time; use IP addresses instead of FQDNs in backend pools if DNS is slow

### Scenario 5: Traffic Manager Endpoint Degraded

- **Symptoms**: Traffic Manager shows endpoint as `Degraded`, traffic fails over to secondary
- **Root Causes**:
  - Backend application not responding to TM probe path with expected status code
  - Probe path returns redirect (3xx) — TM treats 3xx as failure unless configured otherwise
  - Firewall blocking TM probe source IPs
  - Backend DNS resolution failing (for external endpoints)
  - Endpoint manually disabled
- **Detection**:
  ```bash
  az network traffic-manager endpoint show \
    --resource-group <rg> --profile-name <profile> \
    --name <endpoint> --type azureEndpoints

  # Check the probe URL manually
  curl -v https://<endpoint-fqdn>/<probe-path>
  ```
- **Resolution**: Ensure probe path returns 200-299; allow Traffic Manager probe IPs in firewall; verify endpoint health independently

### Scenario 6: Asymmetric Routing with Internal LB + UDR

- **Symptoms**: Traffic to ILB works one direction, responses are dropped. Client connects but gets no response.
- **Root Causes**:
  - UDR on the backend subnet sends return traffic through an NVA (firewall), but the original request came directly to the ILB
  - The NVA sees only the response (not the original request) and drops it as an unknown session
  - This is the most common ILB + NVA issue
- **Architecture that triggers this**:
  ```
  Client → ILB → Backend VM → (UDR → NVA) → Client
  But original path was: Client → ILB → Backend VM (no NVA)
  ```
- **Resolution**:
  - Ensure symmetric routing: if traffic arrives through the NVA, responses must also go through the NVA
  - Use the NVA/firewall as the next hop for both the client subnet AND the backend subnet
  - Or use source NAT on the ILB (Floating IP disabled) so the backend responds to the ILB IP, which then forwards back to the client on the correct path

### Scenario 7: HA Ports Rule Conflicts

- **Symptoms**: Cannot create individual port rules; existing traffic on specific ports stops working after adding HA ports rule
- **Root Causes**:
  - HA ports rule and individual port rules on the **same frontend IP** are incompatible
  - Adding an HA ports rule overrides all individual port rules on that frontend
- **Resolution**: Use separate frontend IPs — one for HA ports, another for individual port rules. Or use HA ports for everything (simplifies configuration for NVAs).

### Scenario 8: Application Gateway Subnet Too Small

- **Symptoms**: Application Gateway fails to scale out, unhealthy state, or provisioning failures
- **Root Causes**:
  - Subnet too small (less than /26) — AppGW v2 needs IPs for each instance plus infrastructure
  - Other resources in the AppGW subnet consuming IP addresses
  - IP exhaustion in the subnet during autoscale events
- **Detection**:
  ```bash
  # Check subnet address space and usage
  az network vnet subnet show --resource-group <rg> --vnet-name <vnet> \
    --name <appgw-subnet> --query '{prefix:addressPrefix, delegations:delegations}'
  ```
- **Resolution**: Resize to at least /24 for production (allows 251 usable IPs); migrate AppGW to a larger subnet; remove any non-AppGW resources from the subnet

### Scenario 9: Backend Pool Members Not Receiving Traffic

- **Symptoms**: Some backends receive traffic, others don't; uneven distribution
- **Root Causes**:
  - Health probe misconfiguration — probe succeeding on some backends but not others
  - Backend VM in `Stopped (deallocated)` state still in the pool
  - Backend added to pool but application not yet deployed/started
  - Availability zone mismatch — LB is not zone-redundant but backends span zones
  - Backend NIC not associated with the LB backend pool (even though VM is in the "backend pool" conceptually)
- **Detection**:
  ```bash
  # Check per-backend health
  az monitor metrics list --resource <lb-resource-id> \
    --metric "DipAvailability" --interval PT1M --aggregation Average \
    --filter "BackendIPAddress eq '<backend-ip>'"
  ```
- **Resolution**: Verify probe health per backend; ensure all backends are running and listening; confirm NIC is in the backend pool

### Scenario 10: Cross-Region Failover Not Working

- **Symptoms**: Primary region is down but clients still connect to it; failover is slow
- **Root Causes (Traffic Manager)**:
  - DNS TTL too high — clients cache the old DNS record
  - Client-side DNS resolver caching beyond TTL
  - Probe interval is 30 seconds + 3 failures = 90 seconds minimum detection time
  - Nested profile MinChildEndpoints misconfigured
- **Root Causes (Cross-Region LB)**:
  - Regional LB health probe interval too long
  - Backend not properly failed in regional LB (regional probe still passing)
- **Resolution**: Reduce Traffic Manager DNS TTL (minimum 0, recommend 30-60s); use fast probing (10-second interval); for Cross-Region LB, ensure regional health probes detect failures quickly

---

## Troubleshooting Toolkit

### Load Balancer Metrics (Azure Monitor)

| Metric | What It Shows | Alert Threshold |
|---|---|---|
| `DipAvailability` | Backend health probe status (%) | < 100% → backend down |
| `VipAvailability` | Frontend availability (%) | < 100% → LB frontend issue |
| `SnatConnectionCount` | Outbound SNAT connections | Filter by `Failed` state |
| `UsedSnatPorts` | SNAT ports in use per backend | > 80% of allocated |
| `ByteCount` | Total bytes through LB | Baseline deviation |
| `PacketCount` | Total packets through LB | Baseline deviation |

```kusto
// KQL: Load Balancer health probe status over time
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "DipAvailability"
| summarize AvgHealth=avg(Average) by bin(TimeGenerated, 5m), Resource
| order by TimeGenerated desc
```

### Application Gateway Diagnostics

Enable diagnostic logs to Log Analytics:
- **Access Log**: Every request — client IP, URL, status code, backend server, latency
- **Performance Log**: Per-instance throughput, request count, failed requests, backend health
- **Firewall Log (WAF)**: Matched rules, blocked/detected requests

```kusto
// KQL: AppGW backend response time percentiles
AzureDiagnostics
| where ResourceType == "APPLICATIONGATEWAYS"
| where Category == "ApplicationGatewayAccessLog"
| extend BackendTime = todouble(timeTaken_d)
| summarize P50=percentile(BackendTime, 50),
            P95=percentile(BackendTime, 95),
            P99=percentile(BackendTime, 99)
    by bin(TimeGenerated, 5m)
| order by TimeGenerated desc

// KQL: Backend health over time
AzureDiagnostics
| where ResourceType == "APPLICATIONGATEWAYS"
| where Category == "ApplicationGatewayAccessLog"
| summarize Total=count(), Failures=countif(httpStatus_d >= 500)
    by bin(TimeGenerated, 5m), serverRouted_s
| extend FailureRate = round(100.0 * Failures / Total, 2)
| order by TimeGenerated desc
```

### Traffic Manager Endpoint Status

```bash
# List all endpoints and their monitor status
az network traffic-manager endpoint list \
  --resource-group <rg> --profile-name <profile> \
  --query '[].{name:name, status:endpointStatus, monitor:endpointMonitorStatus, target:target}'

# DNS resolution test — what does TM return?
nslookup <profile-name>.trafficmanager.net
```

### SNAT Port Usage Investigation

```bash
# Get SNAT connection count, split by state
az monitor metrics list --resource <lb-resource-id> \
  --metric "SnatConnectionCount" --interval PT5M --aggregation Total \
  --filter "ConnectionState eq 'Failed' or ConnectionState eq 'Attempted'"

# Get used SNAT ports per backend
az monitor metrics list --resource <lb-resource-id> \
  --metric "UsedSnatPorts" --interval PT1M --aggregation Max \
  --filter "BackendIPAddress eq '*'"
```

### Connection Draining Verification

```bash
# Application Gateway — check connection draining setting
az network application-gateway show --resource-group <rg> --name <appgw> \
  --query 'backendHttpSettingsCollection[].{name:name, drainTimeout:connectionDraining.drainTimeoutInSec, enabled:connectionDraining.enabled}'

# Load Balancer — TCP reset on idle (helps with connection cleanup)
az network lb rule show --resource-group <rg> --lb-name <lb> --name <rule> \
  --query '{enableTcpReset:enableTcpReset, idleTimeoutInMinutes:idleTimeoutInMinutes}'
```

---

## Best Practices

### Health Probe Design

- **Always use custom HTTP probes** (not TCP) when the backend serves HTTP — TCP only confirms the port is open, not that the app is healthy
- Probe path should check real dependencies (database, cache) — not just return 200 unconditionally
- But **don't make probes too deep** — if a non-critical dependency fails, don't take down the entire backend
- Use a dedicated `/health` or `/healthz` endpoint that returns 200 when ready to serve traffic
- Set probe interval to 5-15 seconds and unhealthy threshold to 2-3 failures
- For Application Gateway, **always** set the probe hostname to match the backend's expected `Host` header

### SNAT Exhaustion Prevention

1. **Use NAT Gateway** for all subnets with outbound internet traffic — this is the #1 recommendation
2. Never rely on default outbound access (deprecated)
3. Implement connection pooling (HTTP keep-alive, database connection pools)
4. Monitor `UsedSnatPorts` and `SnatConnectionCount (Failed)` metrics — alert at 80% utilization
5. If using outbound rules, allocate at least 1024 ports per backend instance for light workloads, 4096+ for connection-heavy workloads

### Application Gateway Sizing

- Use **autoscaling** (min 2 instances for production with zone redundancy)
- Subnet size: **/24 minimum** for production to accommodate scale-out
- WAF adds overhead — benchmark with WAF enabled before going to production
- Set appropriate request timeouts — default 20s is too low for many real backends (increase to 30-60s)
- Enable **connection draining** with at least 30-second timeout
- Use Key Vault integration for SSL certificates — avoids manual cert rotation
- Place AppGW and backends in the **same region and VNet** to minimize latency

### Multi-Tier Load Balancing Patterns

**Pattern 1: Front Door → Application Gateway → VMs**
- Front Door handles global load balancing, edge caching, global WAF
- Application Gateway handles regional L7 routing, WAF, SSL termination
- VMs run the application

**Pattern 2: Front Door → Internal Load Balancer → VMs**
- For non-HTTP backends or when regional L7 routing is not needed
- Front Door connects via Private Link to the internal LB

**Pattern 3: Traffic Manager → Application Gateway (per region)**
- DNS-based failover between regional Application Gateways
- Simpler than Front Door but slower failover (DNS TTL dependent)

**Pattern 4: External LB → NVA (HA ports) → Internal LB → VMs**
- Common in hub-spoke with NVA inspection
- External LB receives inbound traffic, sends to NVA pool
- NVA inspects and forwards to internal LB fronting the application tier
- **Both LBs must use Standard SKU**

### NSG Rules for Load Balancers

```text
# Required NSG rules for Load Balancer backends:
Inbound:
  - Allow from AzureLoadBalancer service tag on probe port (source: 168.63.129.16)
  - Allow from client source ranges on application ports

# Required NSG rules for Application Gateway subnet:
Inbound:
  - Allow from Internet on 80/443 (or client ranges)
  - Allow from GatewayManager service tag on 65200-65535 (v2 health probes)
Outbound:
  - Allow to backend subnet on backend ports
  - Allow to Internet for CRL checks and Azure dependencies
```

---

## Quick Reference: CLI Commands

```bash
# --- Load Balancer ---
# List all load balancers
az network lb list --resource-group <rg> -o table

# Show backend pool health
az network lb show --resource-group <rg> --name <lb> \
  --query 'backendAddressPools[].{name:name, count:length(backendAddresses)}'

# List LB rules
az network lb rule list --resource-group <rg> --lb-name <lb> -o table

# List probes
az network lb probe list --resource-group <rg> --lb-name <lb> -o table

# --- Application Gateway ---
# Show backend health
az network application-gateway show-backend-health \
  --resource-group <rg> --name <appgw>

# List listeners
az network application-gateway http-listener list \
  --resource-group <rg> --gateway-name <appgw> -o table

# List URL path maps
az network application-gateway url-path-map list \
  --resource-group <rg> --gateway-name <appgw>

# --- Traffic Manager ---
# Show profile and routing method
az network traffic-manager profile show \
  --resource-group <rg> --name <profile> \
  --query '{routing:trafficRoutingMethod, dns:dnsConfig.fqdn, ttl:dnsConfig.ttl}'

# List endpoints with status
az network traffic-manager endpoint list \
  --resource-group <rg> --profile-name <profile> -o table

# --- Cross-Region Load Balancer ---
# Same CLI as Standard LB, but with tier=Global
az network lb show --resource-group <rg> --name <global-lb> \
  --query '{sku:sku, tier:sku.tier}'
```
