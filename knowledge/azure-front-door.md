# Azure Front Door (Standard/Premium) — SRE Knowledge Base

## Overview

Azure Front Door (AFD) is Microsoft's modern cloud CDN, global load balancer, and application delivery platform. It operates at Layer 7 (HTTP/HTTPS) and leverages Microsoft's global edge network to accelerate and protect web applications.

### Key Capabilities

- **Global HTTP load balancing** — Distributes traffic across origins in multiple regions
- **CDN / content caching** — Caches static and dynamic content at edge POPs
- **Web Application Firewall (WAF)** — Managed and custom rule sets for L7 protection
- **SSL/TLS offload** — Terminates TLS at the edge, supports end-to-end encryption
- **URL-based routing** — Path, header, and query-string routing via rules engine
- **Health monitoring** — Active health probes with automatic origin failover

### Standard vs Premium Tier

| Feature | Standard | Premium |
|---|---|---|
| Custom domains & TLS | ✅ | ✅ |
| Caching & compression | ✅ | ✅ |
| Rules engine | ✅ | ✅ |
| WAF with custom rules | ✅ | ✅ |
| WAF managed rule sets (DRS/OWASP) | ❌ | ✅ |
| Bot protection | ❌ | ✅ |
| Private Link origins | ❌ | ✅ |
| Enhanced analytics & reports | ❌ | ✅ |
| Microsoft Threat Intelligence feed | ❌ | ✅ |

**SRE note:** If you need Private Link to origins or managed WAF rule sets (DRS), Premium is required. Standard tier WAF only supports custom rules and rate limiting.

---

## Architecture

### Microsoft Global Edge Network

Azure Front Door operates on Microsoft's global edge network spanning 180+ POP (Point of Presence) locations across 65+ metro areas. Every POP runs AFD software and can serve cached content or proxy to origins.

### Anycast Routing

AFD uses **BGP Anycast** to advertise the same IP address from all POPs globally. When a client resolves an AFD endpoint (e.g., `myapp.azurefd.net`), DNS returns the Anycast IP. The client's TCP connection is routed by the internet to the nearest POP based on BGP path selection.

### Core Resource Model

```
Front Door Profile (Standard or Premium)
├── Endpoint(s)              # e.g., myapp-abc123.z01.azurefd.net
│   └── Route(s)             # Maps domain + path pattern → origin group
│       ├── Domain association
│       ├── Path pattern(s)
│       └── Rules engine reference (optional)
├── Origin Group(s)          # Logical grouping of backends
│   ├── Origin 1             # e.g., App Service, VM, Storage, external
│   ├── Origin 2
│   ├── Health probe config
│   └── Load balancing settings
├── Custom Domain(s)         # CNAME or apex domain mapped to endpoint
├── Rule Set(s)              # Ordered rules for request/response modification
└── Security Policy(ies)     # WAF policy association to domains
```

### Traffic Flow

1. Client DNS resolves `www.contoso.com` → CNAME to `myapp.azurefd.net` → Anycast IP
2. Client TCP/TLS handshake terminates at nearest POP
3. AFD evaluates routes: matches domain + path pattern → selects origin group
4. Rules engine executes (modify headers, redirect, rewrite URL, etc.)
5. AFD selects healthiest/closest origin from origin group
6. AFD opens (or reuses) a backend connection to the origin
7. Response flows back through the POP; cacheable responses are stored at the edge

---

## Routing

### Endpoints and Routes

Each **endpoint** has a system-generated hostname (`<name>.azurefd.net`). One or more **routes** define how requests reaching that endpoint are handled.

A route matches on:
- **Domains** — Which custom domain(s) or the endpoint hostname
- **Path patterns** — e.g., `/api/*`, `/images/*`, `/*` (catch-all)
- **Accepted protocols** — HTTP, HTTPS, or both

Routes are evaluated in specificity order: more specific path patterns match first.

### Origin Groups and Origin Selection

An **origin group** contains one or more origins plus:
- **Health probe settings** — Protocol, path, interval, method
- **Load balancing settings** — Sample size, successful samples required, latency sensitivity

#### Origin Selection Algorithm

1. **Remove unhealthy origins** — Origins failing health probes are excluded
2. **Priority filtering** — Only origins with the lowest priority value are considered (lower = higher priority)
3. **Latency bucket** — Among same-priority origins, AFD groups those within the latency sensitivity window (default 0 ms = only fastest)
4. **Weighted distribution** — Traffic is distributed among the latency bucket by weight ratio

**Example:** If Origin A (priority 1, weight 50) and Origin B (priority 1, weight 50) are both healthy and within latency sensitivity, traffic splits 50/50. If Origin C has priority 2, it only receives traffic when all priority-1 origins are unhealthy.

### Caching Behavior

AFD caches responses at each POP based on:
- **Cache key** — Default: URL path + query string. Configurable via rules engine.
- **Cache duration** — Honors origin `Cache-Control` / `Expires` headers, or override via rules
- **Query string behavior** — Include all, ignore all, or include specific query params in cache key

Caching is configured per route:
- **Enable caching** — Toggle on the route
- **Query string caching behavior** — `IgnoreQueryString`, `UseQueryString`, `IgnoreSpecifiedQueryStrings`, `IncludeSpecifiedQueryStrings`
- **Compression** — Enable dynamic compression for MIME types

### Rules Engine

Rule sets contain ordered rules, each with **conditions** (match on headers, URL, query string, request method, etc.) and **actions**:

| Action | Description |
|---|---|
| Route configuration override | Change origin group, caching, or forwarding protocol |
| URL redirect | 301/302/307/308 redirect |
| URL rewrite | Rewrite the URL path sent to origin |
| Modify request header | Add, overwrite, append, or delete request headers |
| Modify response header | Add, overwrite, append, or delete response headers |

Rules are processed in order within a rule set. Multiple rule sets can be associated with a route and are processed in the assigned order.

---

## Security

### Web Application Firewall (WAF)

WAF policies are associated with custom domains via **security policies** on the AFD profile. A security policy maps one or more domains to a WAF policy.

#### Managed Rule Sets (Premium only)

- **Default Rule Set (DRS)** — Microsoft-maintained rules based on OWASP CRS, covering SQL injection, XSS, LFI, RFI, command injection, protocol violations, etc.
- **Bot Manager rule set** — Classifies bots as good (search engines), bad (scrapers), or unknown
- **Microsoft Threat Intelligence** — Blocks known malicious IPs

Managed rules support per-rule actions: `Block`, `Log`, `Redirect`, `Allow` (skip remaining rules), or `AnomalyScoring`.

#### Custom Rules

Evaluated **before** managed rules. Types:
- **Match rules** — Conditions on IP, geo, headers, URI, query string, request body, etc.
- **Rate limit rules** — Threshold-based blocking per source IP (or per custom key) over a time window (1 or 5 minutes)

Priority determines evaluation order (lower number = evaluated first). First matching rule wins.

#### WAF Modes

- **Detection** — Logs matches but does not block. Use for tuning.
- **Prevention** — Actively blocks matching requests.

**SRE best practice:** Always deploy new WAF policies in Detection mode first. Analyze logs for false positives before switching to Prevention.

### Private Link Origins (Premium only)

Premium tier supports connecting to origins via Azure Private Link, keeping traffic on the Microsoft backbone and avoiding public internet exposure. Supported origin types:
- Azure App Service / Functions
- Azure Storage (Blob)
- Azure Application Gateway (internal)
- Internal Load Balancer

The origin must approve the Private Link connection request from AFD. The origin's public endpoint can then be locked down to refuse direct internet traffic.

### TLS / SSL

- **TLS termination at edge** — AFD terminates client TLS at the POP. Minimum TLS version configurable (1.0, 1.2).
- **End-to-end TLS** — AFD re-encrypts traffic to origin over HTTPS. Origin certificate must be valid (signed by a trusted CA).
- **AFD-managed certificates** — Free, auto-rotated TLS certs for custom domains. Requires CNAME validation.
- **Bring Your Own Certificate (BYOC)** — Stored in Azure Key Vault. AFD accesses via managed identity.

---

## Health Probes

### Configuration

Health probes are configured per **origin group**:

| Setting | Default | Description |
|---|---|---|
| Path | `/` | URL path to probe |
| Protocol | HTTP | HTTP or HTTPS |
| Method | HEAD | HEAD or GET |
| Interval | 30 seconds | Probe frequency (30–255 seconds) |

### Health States

- **Healthy** — Origin returns 200 OK within the timeout period
- **Unhealthy** — Origin returns non-200, times out, or TCP connection fails
- **Unknown** — Initial state before first probe completes

The health probe evaluates using the **sample size** and **successful samples required** settings:
- `sampleSize`: Number of recent probes to consider (default: 4)
- `successfulSamplesRequired`: How many of the sample must be healthy (default: 2)

### Failover Behavior

1. When all origins in the highest-priority group become unhealthy, AFD fails over to the next priority group.
2. If **all** origins across **all** priority groups are unhealthy, AFD still sends traffic to the "least unhealthy" origin (or returns 503 if none respond).
3. Health state changes propagate across all POPs independently — different POPs may have different health views.

**SRE note:** Health probe traffic can be significant. Each POP probes each origin independently. With 180+ POPs probing every 30s, expect ~360+ probe requests/minute per origin. Use HEAD method and lightweight probe paths.

---

## DNS and Custom Domains

### Custom Domain Setup

1. **Add custom domain** to the AFD profile
2. **Create DNS record:**
   - **Subdomain (e.g., www):** CNAME → `<endpoint>.azurefd.net`
   - **Apex domain (e.g., contoso.com):** Azure DNS alias record → AFD endpoint resource ID, or CNAME flattening at your DNS provider
3. **Validate domain ownership** — AFD generates a `_dnsauth.<domain>` TXT record value. Create this TXT record in DNS.
4. **Associate domain** with a route

### Domain Validation States

| State | Meaning |
|---|---|
| Pending | Validation TXT record not yet detected |
| Approved | Domain validated successfully |
| Rejected | Validation failed or timed out (7 days) |
| Refreshing | Re-validating after changes |

### Certificate Management

**AFD-managed certificates:**
- Automatically provisioned and renewed by DigiCert
- Requires CNAME to `<endpoint>.azurefd.net` to be in place
- Provisioning can take 10–30 minutes after domain validation
- Does not support apex domains without CNAME flattening

**BYOC (Bring Your Own Certificate):**
- Store PFX/PEM in Azure Key Vault
- Grant AFD managed identity `Key Vault Secrets User` role (or legacy access policy)
- Certificate must include the custom domain as SAN
- You are responsible for renewal — AFD auto-detects new versions in Key Vault

```bash
# Grant AFD access to Key Vault (RBAC model)
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee <afd-managed-identity-object-id> \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>
```

---

## Common Failure Scenarios

### 1. Origin Health Probe Failures

**Symptoms:** 503 errors, origin shows unhealthy in portal, intermittent failures.

**Root causes:**
- Probe path returns non-200 (e.g., `/` redirects to `/login` → 302 = unhealthy)
- Probe hitting wrong port (e.g., origin listens on 8080 but probe uses 443)
- Origin firewall / NSG blocking AFD probe IPs
- Origin overloaded and timing out on probe requests
- HTTPS probe but origin has invalid/self-signed certificate

**Diagnosis:**
```bash
# Check origin health in AFD
az afd origin show --profile-name <profile> --resource-group <rg> \
  --origin-group-name <group> --origin-name <origin>

# Test probe path directly from origin
curl -I https://<origin-hostname>/health
```

**Resolution:**
- Use a dedicated `/health` endpoint that returns 200 with minimal processing
- Ensure probe protocol/port matches the origin listener
- Allow Azure Front Door service tag (`AzureFrontDoor.Backend`) in origin firewall
- Verify the `X-Azure-FDID` header if using origin access restrictions

### 2. Custom Domain Not Resolving

**Symptoms:** DNS resolution fails, browser shows DNS error, domain shows "Pending" in portal.

**Root causes:**
- CNAME record not created or pointing to wrong endpoint hostname
- DNS propagation delay (up to 48 hours for some providers)
- Apex domain without alias record support
- Conflicting DNS records (e.g., A record + CNAME on same name)
- Domain validation TXT record (`_dnsauth`) missing or incorrect

**Diagnosis:**
```bash
# Verify CNAME resolution
nslookup www.contoso.com
# Should return: www.contoso.com -> <endpoint>.azurefd.net -> Anycast IP

# Check validation TXT record
nslookup -type=TXT _dnsauth.www.contoso.com
```

**Resolution:**
- Ensure CNAME points exactly to `<endpoint-name>.azurefd.net`
- For apex domains, use Azure DNS alias records or provider CNAME flattening
- Verify the `_dnsauth` TXT record matches the value shown in the portal
- Wait for DNS TTL expiry if records were recently changed

### 3. Certificate Validation Failures

**Symptoms:** HTTPS not working on custom domain, certificate errors in browser, "Pending" certificate state.

**Root causes:**
- AFD-managed cert: CNAME not in place before certificate provisioning
- AFD-managed cert: Domain validation TXT record missing
- BYOC: Key Vault access denied (missing role assignment or access policy)
- BYOC: Certificate missing the custom domain in SAN
- BYOC: Certificate expired or in wrong format
- BYOC: Key Vault firewall blocking AFD

**Diagnosis:**
```bash
# Check certificate status
az afd custom-domain show --profile-name <profile> --resource-group <rg> \
  --custom-domain-name <domain-name> --query "tlsSettings"

# Verify Key Vault access (BYOC)
az keyvault secret show --vault-name <vault> --name <cert-name>
```

**Resolution:**
- For AFD-managed: ensure CNAME and `_dnsauth` TXT are in place, wait up to 30 min
- For BYOC: grant `Key Vault Secrets User` to AFD's managed identity
- For BYOC: ensure Key Vault network rules allow trusted Microsoft services
- Verify certificate SAN includes the exact custom domain name

### 4. WAF False Positives Blocking Legitimate Traffic

**Symptoms:** Legitimate requests getting 403, users reporting blocked access, specific API calls failing.

**Root causes:**
- Managed rule matching legitimate request body (e.g., SQL-like syntax in form data)
- Overly broad custom rule matching legitimate geo/IP ranges
- Rate limit rule threshold too low for legitimate traffic patterns
- Bot protection misclassifying legitimate automated clients

**Diagnosis:**
```kusto
// Find blocked requests with rule details
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorWebApplicationFirewallLog"
| where action_s == "Block"
| project TimeGenerated, clientIP_s, requestUri_s, ruleName_s, 
    ruleGroup_s, details_msg_s, policy_s
| order by TimeGenerated desc
| take 100
```

**Resolution:**
- Identify the specific rule ID causing false positives
- Create an exclusion for that rule (e.g., exclude specific request header, cookie, or body field)
- For custom rules, refine match conditions (narrow IP range, add path condition)
- Switch WAF to Detection mode temporarily to assess impact
- Consider per-rule action override: change from Block to Log for problematic rules

### 5. Caching Serving Stale Content

**Symptoms:** Users see outdated content, deployments not reflected, inconsistent content across regions.

**Root causes:**
- Long cache TTL with no purge after deployment
- Origin `Cache-Control` headers misconfigured
- Query string not included in cache key (different content served for same path)
- Rules engine overriding cache behavior unexpectedly

**Diagnosis:**
```bash
# Check response cache headers
curl -I https://www.contoso.com/page
# Look for: X-Cache (HIT/MISS), Cache-Control, Age, X-Azure-Ref

# Purge cache
az afd endpoint purge --resource-group <rg> --profile-name <profile> \
  --endpoint-name <endpoint> --content-paths "/*"
```

**Resolution:**
- Implement cache purge in deployment pipelines
- Set appropriate `Cache-Control` headers on origin responses
- Use versioned URLs (e.g., `/app.v2.js`) for immutable content
- Verify query string caching behavior on the route
- Check rules engine for cache override actions

### 6. Routing Rules Not Matching Expected Traffic

**Symptoms:** Requests going to wrong origin group, 404 errors, unexpected redirects.

**Root causes:**
- Path pattern not matching (case sensitivity, missing wildcard)
- More specific route on another endpoint matching first
- Domain not associated with the correct route
- Rules engine redirect/rewrite taking precedence
- Protocol mismatch (HTTP request but route only accepts HTTPS)

**Diagnosis:**
- Review route configuration: domain associations, path patterns, accepted protocols
- Check rules engine rule sets for redirects or origin group overrides
- Test with `curl -v` to see exact request path and response headers
- Check `X-Azure-Ref` header for request tracing

**Resolution:**
- Use `/*` catch-all on default route, more specific patterns on specialized routes
- Ensure custom domains are associated with the correct route(s)
- Verify path patterns include leading `/` and proper wildcards
- Check rule set ordering — rules execute in defined order

### 7. Private Link Origin Connection Failures (Premium)

**Symptoms:** 502/503 errors, Private Link connection shows "Pending" or "Rejected".

**Root causes:**
- Private Link connection not approved on the origin resource
- Origin resource doesn't support Private Link
- Network configuration mismatch (wrong sub-resource or region)
- Origin application not listening on the expected port

**Diagnosis:**
```bash
# Check Private Link connection status
az afd origin show --profile-name <profile> --resource-group <rg> \
  --origin-group-name <group> --origin-name <origin> \
  --query "sharedPrivateLinkResource"
```

**Resolution:**
- Approve the Private Link connection on the origin resource (App Service, Storage, etc.)
- Verify the sub-resource type is correct (e.g., `sites` for App Service)
- Ensure origin application is listening and healthy on the configured port
- Check origin-side logs for incoming connection attempts

### 8. High Latency Due to Poor Origin Selection

**Symptoms:** Slow response times, requests routing to distant origins, suboptimal POP selection.

**Root causes:**
- Latency sensitivity set to 0 ms (only fastest origin used, no distribution)
- All origins in single region (no geographic distribution)
- Origin overloaded causing slow responses (but still "healthy")
- DNS resolver not returning nearest POP (client using remote DNS)
- Caching disabled for cacheable content (every request hits origin)

**Resolution:**
- Deploy origins in multiple regions close to user populations
- Set latency sensitivity appropriately (e.g., 50 ms) for geographic distribution
- Enable caching for static content to reduce origin load
- Monitor origin response times via AFD metrics
- Consider origin response timeout settings

### 9. 503 Errors — All Origins Unhealthy

**Symptoms:** 503 Service Unavailable for all requests, all origins showing unhealthy.

**Root causes:**
- Origin service outage across all regions
- Health probe misconfiguration marking healthy origins as unhealthy
- Origin firewall blocking all AFD POP IPs after a security rule change
- DNS resolution failure for origin hostname
- Certificate mismatch when probing HTTPS origins

**Diagnosis:**
```kusto
// Check health probe status over time
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorHealthProbeLog"
| where TimeGenerated > ago(1h)
| summarize HealthyCount=countif(result_s == "Healthy"),
    UnhealthyCount=countif(result_s != "Healthy") 
    by bin(TimeGenerated, 5m), originName_s
| order by TimeGenerated desc
```

**Resolution:**
- Verify origin services are running and accessible directly
- Test health probe path manually from an external source
- Check origin NSG/firewall allows `AzureFrontDoor.Backend` service tag
- Verify origin hostname resolves correctly
- Check if probe path application logic has changed (new auth requirement, etc.)

---

## Troubleshooting

### Diagnostic Logs

Enable diagnostic settings on the AFD profile to send logs to Log Analytics, Storage, or Event Hub.

| Log Category | Description |
|---|---|
| `FrontDoorAccessLog` | Every request processed by AFD — status code, latency, cache status |
| `FrontDoorHealthProbeLog` | Health probe results per origin per POP |
| `FrontDoorWebApplicationFirewallLog` | WAF evaluation results — matched rules, actions taken |

```bash
# Enable diagnostic logs to Log Analytics
az monitor diagnostic-settings create \
  --name "afd-diag" \
  --resource <afd-resource-id> \
  --workspace <log-analytics-workspace-id> \
  --logs '[
    {"category":"FrontDoorAccessLog","enabled":true},
    {"category":"FrontDoorHealthProbeLog","enabled":true},
    {"category":"FrontDoorWebApplicationFirewallLog","enabled":true}
  ]'
```

### Key Metrics (Azure Monitor)

| Metric | Description | Alert Threshold Guidance |
|---|---|---|
| `RequestCount` | Total requests | Baseline for anomaly detection |
| `OriginRequestCount` | Requests forwarded to origin | Spike = cache miss increase |
| `TotalLatency` | Client → AFD → Origin → AFD → Client | > 500 ms investigate |
| `OriginLatency` | AFD → Origin → AFD | > 200 ms investigate origin perf |
| `OriginHealthPercentage` | % of healthy origins | < 100% = failover in progress |
| `ByteCount` | Total bytes served | Bandwidth monitoring |
| `WebApplicationFirewallRequestCount` | WAF-evaluated requests | Split by action for block rate |
| `4XXErrorPercentage` | Client error rate | > 5% investigate |
| `5XXErrorPercentage` | Server error rate | > 1% investigate immediately |

### Common KQL Queries

#### Request Latency Analysis
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| extend totalLatency = toreal(timeTaken_s) * 1000
| summarize 
    p50=percentile(totalLatency, 50),
    p95=percentile(totalLatency, 95),
    p99=percentile(totalLatency, 99),
    avg=avg(totalLatency)
    by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

#### Error Rate by Status Code
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| summarize count() by httpStatusCode_s, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

#### Cache Hit Ratio
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| extend isCacheHit = cacheStatus_s in ("HIT", "PARTIAL_HIT", "REMOTE_HIT")
| summarize 
    TotalRequests = count(),
    CacheHits = countif(isCacheHit),
    CacheMisses = countif(not(isCacheHit)),
    HitRatio = round(100.0 * countif(isCacheHit) / count(), 2)
    by bin(TimeGenerated, 15m)
| order by TimeGenerated desc
```

#### Top Blocked WAF Rules
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorWebApplicationFirewallLog"
| where action_s == "Block"
| where TimeGenerated > ago(24h)
| summarize BlockCount=count() by ruleName_s, ruleGroup_s
| order by BlockCount desc
| take 20
```

#### Origin Health Over Time
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorHealthProbeLog"
| where TimeGenerated > ago(6h)
| summarize 
    Healthy = countif(result_s == "Healthy"),
    Unhealthy = countif(result_s != "Healthy")
    by bin(TimeGenerated, 5m), originName_s
| extend HealthPct = round(100.0 * Healthy / (Healthy + Unhealthy), 1)
| order by TimeGenerated desc
```

#### Requests by Client Country and POP
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| summarize RequestCount=count() by clientCountry_s, pop_s
| order by RequestCount desc
| take 20
```

#### Slow Requests Investigation
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.CDN"
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| where toreal(timeTaken_s) > 2.0
| project TimeGenerated, clientIP_s, requestUri_s, 
    httpStatusCode_s, timeTaken_s, originName_s, 
    cacheStatus_s, pop_s
| order by toreal(timeTaken_s) desc
| take 50
```

### The X-Azure-Ref Header

Every AFD response includes `X-Azure-Ref`, a unique request identifier. This is critical for:
- Correlating client-reported issues to backend logs
- Opening support tickets with Microsoft (always include this value)
- Tracing a request through the AFD pipeline

---

## Best Practices

### Origin Protection

- **Restrict origin access** to only AFD traffic:
  - Use the `AzureFrontDoor.Backend` service tag in NSG / firewall rules
  - Validate the `X-Azure-FDID` header matches your AFD profile ID
  - For maximum security, use **Private Link origins** (Premium tier)
- **Never expose origin directly** — all traffic should flow through AFD

```bash
# Get your AFD profile's Front Door ID
az afd profile show --profile-name <profile> --resource-group <rg> \
  --query "frontDoorId" -o tsv
```

The origin should validate: `X-Azure-FDID` header == your profile's Front Door ID.

### Session Affinity

- Enable **session affinity** on origin groups when needed (sticky sessions)
- AFD uses a cookie (`ASLBSA`) to pin a client to an origin
- Avoid reliance on session affinity where possible — prefer stateless architectures
- Session affinity breaks if the pinned origin becomes unhealthy (client moves to another origin)

### Compression

- Enable compression on routes for text-based MIME types (HTML, CSS, JS, JSON, SVG, XML)
- AFD compresses at the edge if origin doesn't provide compressed response
- Ensure origin `Accept-Encoding` handling is correct
- Don't compress already-compressed formats (images, video, fonts)

### Caching Strategy

- **Static assets** (JS, CSS, images): Long TTL (days/weeks) with versioned filenames
- **API responses**: Generally no-cache, unless idempotent and safe to cache
- **HTML pages**: Short TTL (minutes) or no-cache for personalized content
- Use `Cache-Control: private` for user-specific content (AFD won't cache it)
- Implement cache purge in CI/CD pipelines
- Use query string cache keys only when query params change content

### WAF Tuning

1. **Start in Detection mode** — Analyze logs for 1–2 weeks before enabling Prevention
2. **Review false positives** — Create exclusions for known-good patterns
3. **Use custom rules for allowlisting** — Higher priority than managed rules
4. **Rate limiting** — Set thresholds based on observed legitimate traffic + headroom
5. **Monitor regularly** — WAF rule set updates from Microsoft can change behavior
6. **Per-rule overrides** — Disable or change action for specific managed rules rather than entire rule groups

### Monitoring and Alerting

- **Alert on `OriginHealthPercentage` < 100%** — Early warning of origin issues
- **Alert on `5XXErrorPercentage` > 1%** — Server-side errors affecting users
- **Alert on `TotalLatency` P95 > threshold** — Performance degradation
- **Alert on WAF block rate spikes** — Potential attack or false positive surge
- **Dashboard cache hit ratio** — Drops indicate caching misconfiguration or content changes
- **Set up action groups** to notify on-call SRE team

### Performance Optimization

- Place origins in regions closest to majority user base
- Use multiple origin regions with priority-based routing for DR
- Set latency sensitivity to balance between performance and origin load distribution
- Enable caching aggressively for static content
- Use HTTP/2 for client connections (AFD default)
- Configure appropriate origin timeouts (connect: 30s, response: 60–240s)

---

## Quick Reference: Key Azure CLI Commands

```bash
# List AFD profiles
az afd profile list --resource-group <rg>

# Show profile details
az afd profile show --profile-name <profile> --resource-group <rg>

# List endpoints
az afd endpoint list --profile-name <profile> --resource-group <rg>

# List origin groups
az afd origin-group list --profile-name <profile> --resource-group <rg>

# List origins in a group
az afd origin list --profile-name <profile> --resource-group <rg> \
  --origin-group-name <group>

# List routes
az afd route list --profile-name <profile> --resource-group <rg> \
  --endpoint-name <endpoint>

# List custom domains
az afd custom-domain list --profile-name <profile> --resource-group <rg>

# Purge cached content
az afd endpoint purge --resource-group <rg> --profile-name <profile> \
  --endpoint-name <endpoint> --content-paths "/css/*" "/js/*"

# List WAF policies
az network front-door waf-policy list --resource-group <rg>

# Show WAF policy details
az network front-door waf-policy show --name <policy> --resource-group <rg>
```

---

## Quick Reference: Important Limits

| Limit | Value |
|---|---|
| Profiles per subscription | 500 |
| Endpoints per profile | 10 |
| Custom domains per profile | 100 |
| Origin groups per profile | 100 |
| Origins per origin group | 50 |
| Routes per endpoint | 25 |
| Rule sets per profile | 100 |
| Rules per rule set | 25 |
| Health probe minimum interval | 30 seconds |
| Max request body size (WAF) | 2 MB (Standard) / 8 MB (Premium DRS 2.0+) |
| Cache purge per call | 100 paths |

---

*Last updated: 2025-07. Refer to [Azure Front Door documentation](https://learn.microsoft.com/en-us/azure/frontdoor/) for latest information.*
