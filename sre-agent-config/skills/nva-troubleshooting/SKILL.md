# NVA Troubleshooting Guide

Use this skill when investigating NVA (Network Virtual Appliance) issues in
the hub-spoke topology. The NVAs are Ubuntu 22.04 VMs running iptables and
dnsmasq, behind an Azure Internal Load Balancer with HA ports.

## Quick health check

Run these commands to assess NVA health:

```bash
# Check VM is running
az vm get-instance-view -g netsre-rg -n netsre-hub1-nva \
  --query "instanceView.statuses[1].displayStatus" -o tsv

# Check NIC-level IP forwarding
az network nic show -g netsre-rg -n netsre-hub1-nva-nic \
  --query enableIPForwarding -o tsv

# Check OS-level IP forwarding
az vm run-command invoke -g netsre-rg -n netsre-hub1-nva \
  --command-id RunShellScript \
  --scripts "sysctl net.ipv4.ip_forward"

# Check iptables FORWARD chain (should be ACCEPT)
az vm run-command invoke -g netsre-rg -n netsre-hub1-nva \
  --command-id RunShellScript \
  --scripts "sudo iptables -L FORWARD -n --line-numbers"

# Check SNAT rules (should have RETURN for RFC1918 before MASQUERADE)
az vm run-command invoke -g netsre-rg -n netsre-hub1-nva \
  --command-id RunShellScript \
  --scripts "sudo iptables -t nat -L INTERNET_SNAT -n --line-numbers"

# Check dnsmasq DNS proxy status
az vm run-command invoke -g netsre-rg -n netsre-hub1-nva \
  --command-id RunShellScript \
  --scripts "systemctl is-active dnsmasq && cat /etc/dnsmasq.d/azure-dns.conf"

# Check NVA Load Balancer health probe
az network lb probe show -g netsre-rg --lb-name netsre-hub1-nva-lb \
  -n ssh-probe --query protocol -o tsv
```

Repeat for hub2 NVA by replacing `hub1` with `hub2`.

## Common NVA issues

### IP forwarding disabled (NIC level)
- **Symptom**: No traffic passes through NVA, effective routes look correct
- **Check**: `az network nic show -g netsre-rg -n netsre-hub1-nva-nic --query enableIPForwarding`
- **Fix**: `az network nic update -g netsre-rg -n netsre-hub1-nva-nic --ip-forwarding true`

### IP forwarding disabled (OS level)
- **Symptom**: Same as NIC-level but NIC shows IP forwarding enabled
- **Check**: `sysctl net.ipv4.ip_forward` on the VM (should return `= 1`)
- **Fix**: `sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf`

### iptables DROP in FORWARD chain
- **Symptom**: NVA receives packets (tcpdump shows them) but doesn't forward
- **Check**: `iptables -L FORWARD -n` (look for DROP or REJECT rules)
- **Fix**: `iptables -P FORWARD ACCEPT` or `iptables -D FORWARD <rule-number>`

### iptables blocking specific spoke
- **Symptom**: Traffic to/from one spoke fails, others work
- **Check**: `iptables -L FORWARD -n` (look for rules targeting specific subnets)
- **Fix**: Remove the offending rule with `iptables -D FORWARD <rule-number>`

### SNAT misconfiguration
- **Symptom**: Internet access works but PE traffic fails, or vice versa
- **Check**: `iptables -t nat -L INTERNET_SNAT -n` (RETURN for RFC1918 must come BEFORE MASQUERADE)
- **Fix**: Rebuild SNAT chain with correct rule order

### dnsmasq not running
- **Symptom**: DNS resolution fails from spokes/on-prem, direct IP connectivity works
- **Check**: `systemctl status dnsmasq`
- **Fix**: `systemctl start dnsmasq && systemctl enable dnsmasq`
- **Root cause**: systemd-resolved may conflict on port 53 — stop it first

### NVA LB health probe failing
- **Symptom**: Traffic intermittently fails; LB sends traffic to unhealthy NVA
- **Check**: `az network lb show -g netsre-rg -n netsre-hub1-nva-lb --query "loadBalancingRules[].backendAddressPool"`
- **Fix**: Ensure SSH (port 22) is accessible on the NVA, restart sshd if needed

## NVA architecture

```
Spoke VM → UDR (0.0.0.0/0 → NVA LB) → NVA LB (HA ports) → NVA VM → Destination
                                                                ↓
                                                     iptables FORWARD chain
                                                     iptables nat INTERNET_SNAT
                                                     (MASQUERADE for non-RFC1918)
```

- NVA LB frontend IPs: hub1=10.1.1.200, hub2=10.2.1.200
- NVA VMs: netsre-hub1-nva (10.1.1.4), netsre-hub2-nva (10.2.1.4)
- LB uses HA ports (all ports, all protocols)
- Health probe: TCP port 22 (SSH)
