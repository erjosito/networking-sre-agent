#!/usr/bin/env bash
###############################################################################
# revert-all.sh — Revert ALL fault injections back to healthy state
#
# Usage: ./revert-all.sh [--resource-group <rg>] [--prefix <prefix>] [--vpn-key <key>]
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
RG="netsre-rg"
PREFIX="netsre"
VPN_SHARED_KEY="FaultTestSharedKey123!"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
step()  { echo -e "\n${CYAN}────── $* ──────${NC}"; }

ERRORS=0
try_run() {
    if ! "$@" 2>/dev/null; then
        warn "Command returned non-zero (may be expected if fault was not injected)"
    fi
}

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g) RG="$2"; shift 2 ;;
        --prefix)            PREFIX="$2"; shift 2 ;;
        --vpn-key)           VPN_SHARED_KEY="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./revert-all.sh [--resource-group <rg>] [--prefix <prefix>] [--vpn-key <key>]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Derived names ───────────────────────────────────────────────────────────
# Must match Bicep naming conventions exactly
HUB1_NVA_NIC="${PREFIX}-hub1-nva-nic"
HUB2_NVA_NIC="${PREFIX}-hub2-nva-nic"
HUB1_NVA_VM="${PREFIX}-hub1-nva"
HUB2_NVA_VM="${PREFIX}-hub2-nva"
SPOKE11_RT="${PREFIX}-spoke11-rt"
SPOKE11_VNET="${PREFIX}-spoke11-vnet"
SPOKE11_NSG="${PREFIX}-spoke11-nsg"
HUB1_VNET="${PREFIX}-hub1-vnet"
HUB1_VPN_CONN="${PREFIX}-conn-hub1-to-onprem"
HUB1_TO_SPOKE11_PEER="${PREFIX}-hub1-vnet-to-spoke11"
SPOKE11_TO_HUB1_PEER="spoke11-to-${PREFIX}-hub1-vnet"
HUB1_NVA_LB="${PREFIX}-hub1-nva-lb"
HUB1_NVA_LB_FE="nva-frontend"
FAULT_GW_NSG="${PREFIX}-fault-gw-nsg"

get_lb_frontend_ip() {
    az network lb frontend-ip show \
        -g "$RG" --lb-name "$HUB1_NVA_LB" -n "$HUB1_NVA_LB_FE" \
        --query "privateIPAddress" -o tsv 2>/dev/null || echo "10.1.1.200"
}

info "╔════════════════════════════════════════════════════════════╗"
info "║  REVERTING ALL FAULTS                                     ║"
info "║  Resource Group: ${RG}"
info "║  Prefix:         ${PREFIX}"
info "╚════════════════════════════════════════════════════════════╝"

###############################################################################
# 1. Re-enable IP forwarding on NVA NICs
###############################################################################
step "1/10  Re-enabling IP forwarding on NVA NICs"
try_run az network nic update -g "$RG" -n "$HUB1_NVA_NIC" --ip-forwarding true -o none && \
    ok "Hub1 NVA NIC IP forwarding enabled" || { fail "Hub1 NVA NIC"; ((ERRORS++)); }
try_run az network nic update -g "$RG" -n "$HUB2_NVA_NIC" --ip-forwarding true -o none && \
    ok "Hub2 NVA NIC IP forwarding enabled" || { fail "Hub2 NVA NIC"; ((ERRORS++)); }

###############################################################################
# 2. Restore UDRs
###############################################################################
step "2/10  Restoring UDRs to correct values"
CORRECT_IP=$(get_lb_frontend_ip)
info "LB frontend IP (correct next hop): ${CORRECT_IP}"

# Ensure route table has correct default route
az network route-table route create \
    -g "$RG" --route-table-name "$SPOKE11_RT" -n "default-to-nva" \
    --next-hop-type VirtualAppliance --next-hop-ip-address "$CORRECT_IP" \
    --address-prefix "0.0.0.0/0" -o none 2>/dev/null || \
az network route-table route update \
    -g "$RG" --route-table-name "$SPOKE11_RT" -n "default-to-nva" \
    --next-hop-type VirtualAppliance --next-hop-ip-address "$CORRECT_IP" \
    --address-prefix "0.0.0.0/0" -o none 2>/dev/null || \
    { fail "Spoke11 default route"; ((ERRORS++)); }
ok "Spoke11 default route set to ${CORRECT_IP}"

# Re-attach route table to subnet
az network vnet subnet update \
    -g "$RG" --vnet-name "$SPOKE11_VNET" -n "default" \
    --route-table "$SPOKE11_RT" -o none 2>/dev/null && \
    ok "Route table re-attached to spoke11/default subnet" || \
    { fail "Spoke11 route table attach"; ((ERRORS++)); }

# Disable BGP propagation (so UDRs take precedence)
az network route-table update -g "$RG" -n "$SPOKE11_RT" \
    --disable-bgp-route-propagation true -o none 2>/dev/null && \
    ok "BGP propagation disabled on spoke11 route table" || \
    { fail "BGP propagation"; ((ERRORS++)); }

###############################################################################
# 3. Remove blocking NSG rules
###############################################################################
step "3/10  Removing fault-injection NSG rules"
for RULE in "FaultInject-Block-ICMP" "FaultInject-Block-All-Inbound" "FaultInject-Block-All-Outbound" "FaultInject-Block-SSH"; do
    az network nsg rule delete -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE" -o none 2>/dev/null && \
        ok "Removed ${RULE}" || info "Rule ${RULE} not present (OK)"
done

###############################################################################
# 4. Remove NSG from GatewaySubnet
###############################################################################
step "4/10  Removing NSG from Hub1 GatewaySubnet"
az network vnet subnet update \
    -g "$RG" --vnet-name "$HUB1_VNET" -n "GatewaySubnet" \
    --network-security-group "" -o none 2>/dev/null || \
az network vnet subnet update \
    -g "$RG" --vnet-name "$HUB1_VNET" -n "GatewaySubnet" \
    --remove networkSecurityGroup -o none 2>/dev/null || \
    info "GatewaySubnet NSG already clear (OK)"
az network nsg delete -g "$RG" -n "$FAULT_GW_NSG" -o none 2>/dev/null || true
ok "Hub1 GatewaySubnet NSG cleared"

###############################################################################
# 5. Restore iptables on NVAs
###############################################################################
step "5/10  Restoring iptables on NVA VMs"
az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
    --command-id RunShellScript \
    --scripts "iptables -P FORWARD ACCEPT; iptables -F FORWARD; echo done" -o none 2>/dev/null && \
    ok "Hub1 NVA iptables restored" || { fail "Hub1 NVA iptables"; ((ERRORS++)); }

az vm run-command invoke -g "$RG" -n "$HUB2_NVA_VM" \
    --command-id RunShellScript \
    --scripts "iptables -P FORWARD ACCEPT; iptables -F FORWARD; echo done" -o none 2>/dev/null && \
    ok "Hub2 NVA iptables restored" || { fail "Hub2 NVA iptables"; ((ERRORS++)); }

###############################################################################
# 6. Re-enable OS-level IP forwarding on NVAs
###############################################################################
step "6/10  Restoring OS-level IP forwarding on NVAs"
az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
    --command-id RunShellScript \
    --scripts "sysctl -w net.ipv4.ip_forward=1; grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf && sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf" -o none 2>/dev/null && \
    ok "Hub1 NVA OS forwarding enabled" || { fail "Hub1 NVA OS forwarding"; ((ERRORS++)); }

az vm run-command invoke -g "$RG" -n "$HUB2_NVA_VM" \
    --command-id RunShellScript \
    --scripts "sysctl -w net.ipv4.ip_forward=1; grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf && sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf" -o none 2>/dev/null && \
    ok "Hub2 NVA OS forwarding enabled" || { fail "Hub2 NVA OS forwarding"; ((ERRORS++)); }

###############################################################################
# 7. Restore VNet peerings
###############################################################################
step "7/10  Restoring VNet peerings"
HUB1_ID=$(az network vnet show -g "$RG" -n "${PREFIX}-hub1-vnet" --query id -o tsv 2>/dev/null || echo "")
SPOKE11_ID=$(az network vnet show -g "$RG" -n "${PREFIX}-spoke11-vnet" --query id -o tsv 2>/dev/null || echo "")

if [[ -n "$HUB1_ID" && -n "$SPOKE11_ID" ]]; then
    # Check if peerings exist; create only if missing
    HUB_PEER_STATE=$(az network vnet peering show -g "$RG" --vnet-name "${PREFIX}-hub1-vnet" -n "$HUB1_TO_SPOKE11_PEER" --query peeringState -o tsv 2>/dev/null || echo "MISSING")
    if [[ "$HUB_PEER_STATE" == "MISSING" ]]; then
        az network vnet peering create \
            -g "$RG" --vnet-name "${PREFIX}-hub1-vnet" -n "$HUB1_TO_SPOKE11_PEER" \
            --remote-vnet "$SPOKE11_ID" --allow-vnet-access --allow-forwarded-traffic \
            --allow-gateway-transit -o none 2>/dev/null || true
        ok "Hub1→Spoke11 peering created"
    else
        ok "Hub1→Spoke11 peering already exists (${HUB_PEER_STATE})"
    fi

    SPOKE_PEER_STATE=$(az network vnet peering show -g "$RG" --vnet-name "${PREFIX}-spoke11-vnet" -n "$SPOKE11_TO_HUB1_PEER" --query peeringState -o tsv 2>/dev/null || echo "MISSING")
    if [[ "$SPOKE_PEER_STATE" == "MISSING" ]]; then
        az network vnet peering create \
            -g "$RG" --vnet-name "${PREFIX}-spoke11-vnet" -n "$SPOKE11_TO_HUB1_PEER" \
            --remote-vnet "$HUB1_ID" --allow-vnet-access --allow-forwarded-traffic \
            --use-remote-gateways -o none 2>/dev/null || true
        ok "Spoke11→Hub1 peering created"
    else
        ok "Spoke11→Hub1 peering already exists (${SPOKE_PEER_STATE})"
    fi
else
    warn "Could not resolve VNet IDs — peering restoration skipped"
    ((ERRORS++))
fi

###############################################################################
# 8. Restore VPN connections
###############################################################################
step "8/10  Restoring VPN connections"
HUB1_GW="${PREFIX}-hub1-vpngw"
ONPREM_GW="${PREFIX}-onprem-vpngw"

VPN_STATE=$(az network vpn-connection show -g "$RG" -n "$HUB1_VPN_CONN" --query connectionStatus -o tsv 2>/dev/null || echo "MISSING")
if [[ "$VPN_STATE" == "MISSING" ]]; then
    az network vpn-connection create \
        -g "$RG" -n "$HUB1_VPN_CONN" \
        --vnet-gateway1 "$HUB1_GW" --vnet-gateway2 "$ONPREM_GW" \
        --shared-key "$VPN_SHARED_KEY" \
        --enable-bgp -o none 2>/dev/null || \
    az network vpn-connection create \
        -g "$RG" -n "$HUB1_VPN_CONN" \
        --vnet-gateway1 "$HUB1_GW" --vnet-gateway2 "$ONPREM_GW" \
        --shared-key "$VPN_SHARED_KEY" -o none 2>/dev/null || \
        { fail "VPN connection create"; ((ERRORS++)); }
    ok "VPN connection ${HUB1_VPN_CONN} re-created (may take a few minutes to connect)"
else
    ok "VPN connection already exists (status: ${VPN_STATE})"
fi

###############################################################################
# Summary
###############################################################################
step "REVERT SUMMARY"
if [[ $ERRORS -eq 0 ]]; then
    ok "All faults reverted successfully. Environment should be healthy."
    info "Run ./check-health.sh to verify."
else
    fail "${ERRORS} error(s) during revert. Review output above."
    info "Run ./check-health.sh to identify remaining issues."
fi
