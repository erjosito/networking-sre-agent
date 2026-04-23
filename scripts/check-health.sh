#!/usr/bin/env bash
###############################################################################
# check-health.sh — Verify the Azure networking test environment is healthy
#
# Usage: ./check-health.sh [--resource-group <rg>] [--prefix <prefix>]
#
# Checks IP forwarding, peerings, VPN, route tables, NSGs, and NVA config.
# Prints a summary: HEALTHY or DEGRADED with details.
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
RG="netsre-rg"
PREFIX="netsre"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; }
fail_m(){ echo -e "${RED}[FAIL]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()

check_pass() { ((PASS_COUNT++)); pass "$*"; }
check_fail() { ((FAIL_COUNT++)); FAILURES+=("$*"); fail_m "$*"; }

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g) RG="$2"; shift 2 ;;
        --prefix)            PREFIX="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./check-health.sh [--resource-group <rg>] [--prefix <prefix>]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

info "╔════════════════════════════════════════════════════════════╗"
info "║  HEALTH CHECK                                             ║"
info "║  Resource Group: ${RG}"
info "║  Prefix:         ${PREFIX}"
info "╚════════════════════════════════════════════════════════════╝"

###############################################################################
# 1. IP Forwarding on NVA NICs
###############################################################################
section "1. NVA NIC IP Forwarding"
for HUB in hub1 hub2; do
    NIC="${PREFIX}-${HUB}-nva-nic"
    FWD=$(az network nic show -g "$RG" -n "$NIC" --query "enableIPForwarding" -o tsv 2>/dev/null || echo "ERROR")
    if [[ "$FWD" == "true" ]]; then
        check_pass "${NIC}: IP forwarding enabled"
    else
        check_fail "${NIC}: IP forwarding is ${FWD} (expected: true)"
    fi
done

###############################################################################
# 2. VNet Peerings
###############################################################################
section "2. VNet Peerings"
PEERING_PAIRS=(
    "hub1:spoke11:${PREFIX}-hub1-vnet-to-spoke11"
    "hub1:spoke12:${PREFIX}-hub1-vnet-to-spoke12"
    "hub2:spoke21:${PREFIX}-hub2-vnet-to-spoke21"
    "hub2:spoke22:${PREFIX}-hub2-vnet-to-spoke22"
)
for PAIR in "${PEERING_PAIRS[@]}"; do
    IFS=':' read -r HUB SPOKE PEER_NAME <<< "$PAIR"
    VNET="${PREFIX}-${HUB}-vnet"
    STATE=$(az network vnet peering show -g "$RG" --vnet-name "$VNET" -n "$PEER_NAME" --query peeringState -o tsv 2>/dev/null || echo "MISSING")
    if [[ "$STATE" == "Connected" ]]; then
        check_pass "Peering ${PEER_NAME}: Connected"
    else
        check_fail "Peering ${PEER_NAME}: ${STATE} (expected: Connected)"
    fi
done

###############################################################################
# 3. VPN Connections
###############################################################################
section "3. VPN Connections"
VPN_CONN="${PREFIX}-conn-hub1-to-onprem"
VPN_STATUS=$(az network vpn-connection show -g "$RG" -n "$VPN_CONN" --query connectionStatus -o tsv 2>/dev/null || echo "MISSING")
if [[ "$VPN_STATUS" == "Connected" ]]; then
    check_pass "VPN ${VPN_CONN}: Connected"
elif [[ "$VPN_STATUS" == "Connecting" ]]; then
    warn "VPN ${VPN_CONN}: Connecting (may still be initializing)"
    check_pass "VPN ${VPN_CONN}: ${VPN_STATUS} (acceptable)"
elif [[ "$VPN_STATUS" == "MISSING" ]]; then
    check_fail "VPN ${VPN_CONN}: MISSING (connection does not exist)"
else
    check_fail "VPN ${VPN_CONN}: ${VPN_STATUS} (expected: Connected)"
fi

###############################################################################
# 4. Route Table Associations
###############################################################################
section "4. Route Table Subnet Associations"
SPOKE_RTS=(
    "spoke11:default:${PREFIX}-spoke11-rt"
    "spoke12:default:${PREFIX}-spoke12-rt"
    "spoke21:default:${PREFIX}-spoke21-rt"
    "spoke22:default:${PREFIX}-spoke22-rt"
)
for ENTRY in "${SPOKE_RTS[@]}"; do
    IFS=':' read -r SPOKE SUBNET RT_NAME <<< "$ENTRY"
    VNET="${PREFIX}-${SPOKE}-vnet"
    ATTACHED_RT=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --query "routeTable.id" -o tsv 2>/dev/null || echo "NONE")
    if [[ "$ATTACHED_RT" == *"$RT_NAME"* ]]; then
        check_pass "${VNET}/${SUBNET}: route table ${RT_NAME} attached"
    elif [[ "$ATTACHED_RT" == "NONE" || -z "$ATTACHED_RT" ]]; then
        check_fail "${VNET}/${SUBNET}: no route table attached (expected: ${RT_NAME})"
    else
        check_fail "${VNET}/${SUBNET}: wrong route table attached"
    fi
done

###############################################################################
# 5. UDR Next Hops
###############################################################################
section "5. UDR Default Route Next Hops"
for SPOKE in spoke11 spoke12 spoke21 spoke22; do
    RT="${PREFIX}-${SPOKE}-rt"
    NEXT_HOP=$(az network route-table route show -g "$RG" --route-table-name "$RT" -n "default-to-nva" --query "nextHopIpAddress" -o tsv 2>/dev/null || echo "MISSING")
    NEXT_TYPE=$(az network route-table route show -g "$RG" --route-table-name "$RT" -n "default-to-nva" --query "nextHopType" -o tsv 2>/dev/null || echo "MISSING")
    if [[ "$NEXT_TYPE" == "VirtualAppliance" && "$NEXT_HOP" != "" && "$NEXT_HOP" != "MISSING" && "$NEXT_HOP" != "10.255.255.1" ]]; then
        check_pass "${RT}/default-to-nva: next hop ${NEXT_HOP} (VirtualAppliance)"
    elif [[ "$NEXT_HOP" == "MISSING" ]]; then
        check_fail "${RT}/default-to-nva: route MISSING"
    elif [[ "$NEXT_HOP" == "10.255.255.1" ]]; then
        check_fail "${RT}/default-to-nva: next hop is 10.255.255.1 (wrong — fault injected?)"
    else
        check_fail "${RT}/default-to-nva: unexpected config (type=${NEXT_TYPE}, hop=${NEXT_HOP})"
    fi
done

###############################################################################
# 6. BGP Propagation
###############################################################################
section "6. BGP Route Propagation (should be disabled on spoke RTs)"
for SPOKE in spoke11 spoke12 spoke21 spoke22; do
    RT="${PREFIX}-${SPOKE}-rt"
    BGP_DISABLED=$(az network route-table show -g "$RG" -n "$RT" --query "disableBgpRoutePropagation" -o tsv 2>/dev/null || echo "ERROR")
    if [[ "$BGP_DISABLED" == "true" ]]; then
        check_pass "${RT}: BGP propagation disabled (correct)"
    else
        check_fail "${RT}: BGP propagation enabled (should be disabled to force NVA routing)"
    fi
done

###############################################################################
# 7. NSG Fault-Injection Rules
###############################################################################
section "7. NSG Blocking Rules (should not exist)"
FAULT_RULES=("FaultInject-Block-ICMP" "FaultInject-Block-All-Inbound" "FaultInject-Block-All-Outbound" "FaultInject-Block-SSH")
for SPOKE in spoke11 spoke12 spoke21 spoke22; do
    NSG="${PREFIX}-${SPOKE}-nsg"
    for RULE in "${FAULT_RULES[@]}"; do
        EXISTS=$(az network nsg rule show -g "$RG" --nsg-name "$NSG" -n "$RULE" --query "name" -o tsv 2>/dev/null || echo "")
        if [[ -z "$EXISTS" ]]; then
            # Rule doesn't exist — that's good
            :
        else
            check_fail "${NSG}: fault rule ${RULE} still present"
        fi
    done
done
# Check no NSG on GatewaySubnet
GW_NSG=$(az network vnet subnet show -g "$RG" --vnet-name "${PREFIX}-hub1-vnet" -n "GatewaySubnet" --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")
if [[ -z "$GW_NSG" || "$GW_NSG" == "None" ]]; then
    check_pass "Hub1 GatewaySubnet: no NSG attached (correct)"
else
    check_fail "Hub1 GatewaySubnet: NSG attached (${GW_NSG}) — this can break the gateway"
fi

###############################################################################
# 8. NVA OS-Level Forwarding & iptables
###############################################################################
section "8. NVA OS Configuration (via run-command)"
for HUB in hub1 hub2; do
    VM="${PREFIX}-${HUB}-nva"
    info "Checking ${VM} (this may take a moment)..."

    # Check sysctl ip_forward
    SYSCTL_OUT=$(az vm run-command invoke -g "$RG" -n "$VM" \
        --command-id RunShellScript \
        --scripts "sysctl -n net.ipv4.ip_forward" \
        --query "value[0].message" -o tsv 2>/dev/null || echo "ERROR")
    if echo "$SYSCTL_OUT" | grep -q "1"; then
        check_pass "${VM}: net.ipv4.ip_forward = 1"
    else
        check_fail "${VM}: net.ipv4.ip_forward != 1 (OS forwarding disabled)"
    fi

    # Check iptables FORWARD policy
    IPTABLES_OUT=$(az vm run-command invoke -g "$RG" -n "$VM" \
        --command-id RunShellScript \
        --scripts "iptables -L FORWARD -n --line-numbers 2>/dev/null | head -20" \
        --query "value[0].message" -o tsv 2>/dev/null || echo "ERROR")
    if echo "$IPTABLES_OUT" | grep -qi "policy ACCEPT"; then
        check_pass "${VM}: iptables FORWARD policy is ACCEPT"
    elif echo "$IPTABLES_OUT" | grep -qi "policy DROP"; then
        check_fail "${VM}: iptables FORWARD policy is DROP"
    else
        warn "${VM}: Could not determine iptables FORWARD policy"
    fi

    # Check for spoke-blocking rules
    if echo "$IPTABLES_OUT" | grep -qi "DROP.*10\.11\.0\.0"; then
        check_fail "${VM}: iptables has spoke11-blocking rule"
    fi
done

###############################################################################
# Summary
###############################################################################
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo -e "  Checks: ${TOTAL}   Passed: ${GREEN}${PASS_COUNT}${NC}   Failed: ${RED}${FAIL_COUNT}${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "\n  ${GREEN}████ HEALTHY ████${NC}"
    echo -e "  All checks passed. Environment is in expected state."
else
    echo -e "\n  ${RED}████ DEGRADED ████${NC}"
    echo -e "  ${FAIL_COUNT} issue(s) detected:\n"
    for F in "${FAILURES[@]}"; do
        echo -e "    ${RED}•${NC} ${F}"
    done
    echo ""
    echo -e "  Run ${CYAN}./revert-all.sh -g ${RG} --prefix ${PREFIX}${NC} to fix."
fi
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
