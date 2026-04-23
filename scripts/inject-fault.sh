#!/usr/bin/env bash
###############################################################################
# inject-fault.sh — Fault injection for Azure networking test environment
#
# Usage:
#   ./inject-fault.sh <scenario> [--resource-group <rg>] [--prefix <prefix>] [--revert]
#
# Each scenario injects a specific networking fault. Pass --revert to undo it.
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
RG="netsre-rg"
PREFIX="netsre"
REVERT=false
SCENARIO=""
VPN_SHARED_KEY="FaultTestSharedKey123!"

# ─── Color helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
impact(){ echo -e "${YELLOW}[IMPACT]${NC} $*"; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: ./inject-fault.sh <scenario> [--resource-group <rg>] [--prefix <prefix>] [--revert]

Scenarios:
  ip-forwarding-hub1       Disable IP forwarding on Hub1 NVA NIC
  ip-forwarding-hub2       Disable IP forwarding on Hub2 NVA NIC
  udr-wrong-nexthop        Change spoke11 UDR next hop to wrong IP
  udr-missing-route        Remove default route from spoke11 route table
  udr-detach               Detach route table from spoke11 subnet
  nsg-block-icmp           Add NSG rule blocking ICMP on spoke11 subnet
  nsg-block-all            Add NSG rule blocking all traffic on spoke11 subnet
  nsg-block-ssh            Add NSG rule blocking SSH (port 22) on spoke11 subnet
  nva-iptables-drop        Set iptables FORWARD policy to DROP on hub1 NVA
  nva-iptables-block-spoke Add iptables rule blocking spoke11 traffic on hub1 NVA
  nva-os-forwarding        Disable OS-level IP forwarding on hub1 NVA
  nva-stop-ssh             Stop SSH daemon on both NVAs (LB health probe fails)
  nva-no-internet          Block outbound internet on NVA subnet (UDR 0/0 → None)
  vpn-disconnect           Delete VPN connection between hub1 and on-prem
  bgp-propagation          Enable BGP propagation on spoke11 route table
  gw-disable-bgp-propagation  Disable BGP propagation on Hub1 GatewaySubnet RT
  gateway-nsg              Apply restrictive NSG to hub1 GatewaySubnet
  peering-disconnect       Delete VNet peering between hub1 and spoke11
  peering-no-gateway-transit  Disable AllowGatewayTransit on hub1→spoke11 peering
  peering-no-use-remote-gw   Disable UseRemoteGateways on spoke11→hub1 peering
  multi-fault              Inject multiple faults simultaneously (random 2-3)

Options:
  --resource-group, -g     Resource group name  (default: netsre-rg)
  --prefix                 Resource name prefix (default: netsre)
  --revert                 Undo the specified fault
  --vpn-key                Shared key for VPN connections (used by vpn-disconnect revert)
  --help, -h               Show this help
EOF
    exit 0
}

# ─── Parse arguments ─────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
SCENARIO="$1"; shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g) RG="$2"; shift 2 ;;
        --prefix)            PREFIX="$2"; shift 2 ;;
        --revert)            REVERT=true; shift ;;
        --vpn-key)           VPN_SHARED_KEY="$2"; shift 2 ;;
        --help|-h)           usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

# ─── Derived resource names ─────────────────────────────────────────────────
# Must match Bicep naming conventions exactly
HUB1_NVA_NIC="${PREFIX}-hub1-nva-nic"
HUB2_NVA_NIC="${PREFIX}-hub2-nva-nic"
HUB1_NVA_VM="${PREFIX}-hub1-nva"
HUB2_NVA_VM="${PREFIX}-hub2-nva"
SPOKE11_RT="${PREFIX}-spoke11-rt"
SPOKE11_VNET="${PREFIX}-spoke11-vnet"
SPOKE11_NSG="${PREFIX}-spoke11-nsg"
HUB1_VNET="${PREFIX}-hub1-vnet"
HUB1_GW_RT="${PREFIX}-hub1-gw-rt"
HUB1_VPN_CONN="${PREFIX}-conn-hub1-to-onprem"
HUB1_TO_SPOKE11_PEER="${HUB1_VNET}-to-spoke11"
SPOKE11_TO_HUB1_PEER="spoke11-to-${HUB1_VNET}"
HUB1_NVA_LB="${PREFIX}-hub1-nva-lb"
HUB1_NVA_LB_FE="nva-frontend"
ONPREM_VNET="${PREFIX}-onprem-vnet"
DEFAULT_ROUTE_NAME="default-to-nva"

# Helper: get the LB frontend private IP (used as correct next-hop for spokes)
get_lb_frontend_ip() {
    az network lb frontend-ip show \
        -g "$RG" --lb-name "$HUB1_NVA_LB" -n "$HUB1_NVA_LB_FE" \
        --query "privateIPAddress" -o tsv 2>/dev/null || echo "10.1.1.200"
}

###############################################################################
# Scenario implementations
###############################################################################

# ── ip-forwarding-hub1 ──────────────────────────────────────────────────────
do_ip_forwarding_hub1() {
    if $REVERT; then
        info "Re-enabling IP forwarding on ${HUB1_NVA_NIC}"
        az network nic update -g "$RG" -n "$HUB1_NVA_NIC" --ip-forwarding true -o none
        ok "IP forwarding re-enabled on Hub1 NVA NIC"
    else
        info "Disabling IP forwarding on ${HUB1_NVA_NIC}"
        info "REASON: Without IP forwarding the NVA NIC drops transit traffic at the Azure fabric level."
        az network nic update -g "$RG" -n "$HUB1_NVA_NIC" --ip-forwarding false -o none
        ok "IP forwarding disabled on Hub1 NVA NIC"
        impact "All traffic routed through Hub1 NVA will be black-holed."
        impact "Connection Monitors: spoke11↔spoke12, spoke11↔spoke21, spoke11↔onprem will FAIL."
    fi
}

# ── ip-forwarding-hub2 ──────────────────────────────────────────────────────
do_ip_forwarding_hub2() {
    if $REVERT; then
        info "Re-enabling IP forwarding on ${HUB2_NVA_NIC}"
        az network nic update -g "$RG" -n "$HUB2_NVA_NIC" --ip-forwarding true -o none
        ok "IP forwarding re-enabled on Hub2 NVA NIC"
    else
        info "Disabling IP forwarding on ${HUB2_NVA_NIC}"
        info "REASON: Without IP forwarding the NVA NIC drops transit traffic at the Azure fabric level."
        az network nic update -g "$RG" -n "$HUB2_NVA_NIC" --ip-forwarding false -o none
        ok "IP forwarding disabled on Hub2 NVA NIC"
        impact "All traffic routed through Hub2 NVA will be black-holed."
        impact "Connection Monitors: spoke21↔spoke22, spoke21↔spoke11, spoke22↔onprem will FAIL."
    fi
}

# ── udr-wrong-nexthop ───────────────────────────────────────────────────────
do_udr_wrong_nexthop() {
    local ROUTE_NAME="default-to-nva"
    if $REVERT; then
        local CORRECT_IP
        CORRECT_IP=$(get_lb_frontend_ip)
        info "Restoring spoke11 UDR default route to correct next hop (${CORRECT_IP})"
        az network route-table route update \
            -g "$RG" --route-table-name "$SPOKE11_RT" -n "$ROUTE_NAME" \
            --next-hop-type VirtualAppliance --next-hop-ip-address "$CORRECT_IP" \
            --address-prefix "0.0.0.0/0" -o none
        ok "Spoke11 default route restored to ${CORRECT_IP}"
    else
        local WRONG_IP="10.255.255.1"
        info "Changing spoke11 UDR default-to-nva next hop to unreachable IP (${WRONG_IP})"
        info "REASON: Traffic is sent to a non-existent appliance; packets are dropped."
        az network route-table route update \
            -g "$RG" --route-table-name "$SPOKE11_RT" -n "$ROUTE_NAME" \
            --next-hop-type VirtualAppliance --next-hop-ip-address "$WRONG_IP" \
            --address-prefix "0.0.0.0/0" -o none
        ok "Spoke11 default-to-nva next hop changed to ${WRONG_IP}"
        impact "All outbound traffic from spoke11 will be black-holed."
        impact "Connection Monitors: spoke11→any destination will FAIL."
    fi
}

# ── udr-missing-route ───────────────────────────────────────────────────────
do_udr_missing_route() {
    local ROUTE_NAME="default-to-nva"
    if $REVERT; then
        local CORRECT_IP
        CORRECT_IP=$(get_lb_frontend_ip)
        info "Re-creating default route in spoke11 route table"
        az network route-table route create \
            -g "$RG" --route-table-name "$SPOKE11_RT" -n "$ROUTE_NAME" \
            --next-hop-type VirtualAppliance --next-hop-ip-address "$CORRECT_IP" \
            --address-prefix "0.0.0.0/0" -o none 2>/dev/null || \
        az network route-table route update \
            -g "$RG" --route-table-name "$SPOKE11_RT" -n "$ROUTE_NAME" \
            --next-hop-type VirtualAppliance --next-hop-ip-address "$CORRECT_IP" \
            --address-prefix "0.0.0.0/0" -o none
        ok "Default route restored in spoke11 route table"
    else
        info "Deleting default route from spoke11 route table (${SPOKE11_RT})"
        info "REASON: Without a default route, spoke11 traffic uses Azure default routing (direct to Internet or peering) and bypasses the NVA."
        az network route-table route delete \
            -g "$RG" --route-table-name "$SPOKE11_RT" -n "$ROUTE_NAME" -o none 2>/dev/null || \
            warn "Route already absent — idempotent, continuing."
        ok "Default route removed from spoke11 route table"
        impact "Spoke11 traffic bypasses the NVA firewall. Cross-hub and on-prem traffic may fail."
        impact "Connection Monitors: spoke11↔spoke21, spoke11↔onprem may FAIL or take unexpected path."
    fi
}

# ── udr-detach ───────────────────────────────────────────────────────────────
do_udr_detach() {
    local SUBNET_NAME="default"
    if $REVERT; then
        info "Re-attaching route table ${SPOKE11_RT} to spoke11 default subnet"
        az network vnet subnet update \
            -g "$RG" --vnet-name "$SPOKE11_VNET" -n "$SUBNET_NAME" \
            --route-table "$SPOKE11_RT" -o none
        ok "Route table re-attached to spoke11/default subnet"
    else
        info "Detaching route table from spoke11 default subnet"
        info "REASON: Without a route table the subnet uses only Azure system routes; NVA routing is lost."
        az network vnet subnet update \
            -g "$RG" --vnet-name "$SPOKE11_VNET" -n "$SUBNET_NAME" \
            --route-table "" -o none 2>/dev/null || \
        az network vnet subnet update \
            -g "$RG" --vnet-name "$SPOKE11_VNET" -n "$SUBNET_NAME" \
            --remove routeTable -o none
        ok "Route table detached from spoke11/default subnet"
        impact "Spoke11 workload VM loses all custom routing."
        impact "Connection Monitors: all spoke11 paths will revert to system routes; cross-hub & on-prem FAIL."
    fi
}

# ── nsg-block-icmp ───────────────────────────────────────────────────────────
do_nsg_block_icmp() {
    local RULE_NAME="FaultInject-Block-ICMP"
    if $REVERT; then
        info "Removing ICMP-blocking NSG rule from ${SPOKE11_NSG}"
        az network nsg rule delete -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_NAME" -o none 2>/dev/null || \
            warn "Rule already absent — idempotent."
        ok "ICMP-blocking rule removed"
    else
        info "Adding NSG rule to block ICMP on ${SPOKE11_NSG}"
        info "REASON: Blocks ping/traceroute, simulating a misconfigured NSG."
        az network nsg rule create -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_NAME" \
            --priority 100 --direction Inbound --access Deny --protocol Icmp \
            --source-address-prefixes '*' --destination-address-prefixes '*' \
            --source-port-ranges '*' --destination-port-ranges '*' -o none
        ok "ICMP-blocking rule added to ${SPOKE11_NSG}"
        impact "Ping-based Connection Monitors targeting spoke11 VMs will FAIL."
        impact "TCP-based monitors may still succeed."
    fi
}

# ── nsg-block-all ────────────────────────────────────────────────────────────
do_nsg_block_all() {
    local RULE_IN="FaultInject-Block-All-Inbound"
    local RULE_OUT="FaultInject-Block-All-Outbound"
    if $REVERT; then
        info "Removing all-traffic-blocking NSG rules from ${SPOKE11_NSG}"
        az network nsg rule delete -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_IN" -o none 2>/dev/null || true
        az network nsg rule delete -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_OUT" -o none 2>/dev/null || true
        ok "Blocking rules removed"
    else
        info "Adding NSG rules to block ALL traffic on ${SPOKE11_NSG}"
        info "REASON: Simulates total network isolation of the spoke11 subnet."
        az network nsg rule create -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_IN" \
            --priority 100 --direction Inbound --access Deny --protocol '*' \
            --source-address-prefixes '*' --destination-address-prefixes '*' \
            --source-port-ranges '*' --destination-port-ranges '*' -o none
        az network nsg rule create -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_OUT" \
            --priority 100 --direction Outbound --access Deny --protocol '*' \
            --source-address-prefixes '*' --destination-address-prefixes '*' \
            --source-port-ranges '*' --destination-port-ranges '*' -o none
        ok "All-traffic-blocking rules added to ${SPOKE11_NSG}"
        impact "Spoke11 is completely isolated — no inbound or outbound traffic."
        impact "Connection Monitors: ALL spoke11 paths will FAIL."
    fi
}

# ── nsg-block-ssh ────────────────────────────────────────────────────────────
do_nsg_block_ssh() {
    local RULE_NAME="FaultInject-Block-SSH"
    if $REVERT; then
        info "Removing SSH-blocking NSG rule from ${SPOKE11_NSG}"
        az network nsg rule delete -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_NAME" -o none 2>/dev/null || true
        ok "SSH-blocking rule removed"
    else
        info "Adding NSG rule to block SSH on ${SPOKE11_NSG}"
        info "REASON: Simulates a misconfigured NSG that blocks management access."
        az network nsg rule create -g "$RG" --nsg-name "$SPOKE11_NSG" -n "$RULE_NAME" \
            --priority 100 --direction Inbound --access Deny --protocol Tcp \
            --source-address-prefixes '*' --destination-address-prefixes '*' \
            --source-port-ranges '*' --destination-port-ranges '22' -o none
        ok "SSH-blocking rule added to ${SPOKE11_NSG}"
        impact "SSH connections to spoke11 VMs will FAIL."
        impact "Connection Monitors testing TCP/22 to spoke11 will FAIL."
    fi
}

# ── nva-iptables-drop ────────────────────────────────────────────────────────
do_nva_iptables_drop() {
    if $REVERT; then
        info "Restoring iptables FORWARD policy to ACCEPT on ${HUB1_NVA_VM}"
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "iptables -P FORWARD ACCEPT" -o none
        ok "iptables FORWARD policy set to ACCEPT on Hub1 NVA"
    else
        info "Setting iptables FORWARD policy to DROP on ${HUB1_NVA_VM}"
        info "REASON: The NVA OS silently drops all forwarded packets even though Azure IP forwarding is enabled."
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "iptables -P FORWARD DROP" -o none
        ok "iptables FORWARD policy set to DROP on Hub1 NVA"
        impact "Hub1 NVA drops all transit traffic at the OS level."
        impact "Connection Monitors: spoke11↔spoke12, spoke11↔spoke21, spoke11↔onprem will FAIL."
    fi
}

# ── nva-iptables-block-spoke ─────────────────────────────────────────────────
do_nva_iptables_block_spoke() {
    # Assume spoke11 uses 10.11.0.0/16 — adjust as needed
    local SPOKE11_PREFIX="10.11.0.0/16"
    if $REVERT; then
        info "Removing iptables rule blocking spoke11 traffic on ${HUB1_NVA_VM}"
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "iptables -D FORWARD -s ${SPOKE11_PREFIX} -j DROP 2>/dev/null; iptables -D FORWARD -d ${SPOKE11_PREFIX} -j DROP 2>/dev/null; echo done" -o none
        ok "iptables spoke11 block rules removed on Hub1 NVA"
    else
        info "Adding iptables rules blocking spoke11 (${SPOKE11_PREFIX}) traffic on ${HUB1_NVA_VM}"
        info "REASON: NVA selectively drops traffic to/from spoke11, simulating a firewall misconfiguration."
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "iptables -C FORWARD -s ${SPOKE11_PREFIX} -j DROP 2>/dev/null || iptables -I FORWARD 1 -s ${SPOKE11_PREFIX} -j DROP; iptables -C FORWARD -d ${SPOKE11_PREFIX} -j DROP 2>/dev/null || iptables -I FORWARD 1 -d ${SPOKE11_PREFIX} -j DROP" -o none
        ok "iptables spoke11 block rules added on Hub1 NVA"
        impact "Spoke11 traffic through Hub1 NVA will be dropped."
        impact "Connection Monitors: spoke11↔any via Hub1 NVA will FAIL; spoke12↔spoke21 may still work."
    fi
}

# ── nva-os-forwarding ────────────────────────────────────────────────────────
do_nva_os_forwarding() {
    if $REVERT; then
        info "Re-enabling OS-level IP forwarding (sysctl) on ${HUB1_NVA_VM}"
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "sysctl -w net.ipv4.ip_forward=1; sed -i 's/^net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' /etc/sysctl.conf" -o none
        ok "OS-level IP forwarding re-enabled on Hub1 NVA"
    else
        info "Disabling OS-level IP forwarding (sysctl) on ${HUB1_NVA_VM}"
        info "REASON: Even with Azure NIC IP forwarding enabled, the Linux kernel must also forward packets."
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "sysctl -w net.ipv4.ip_forward=0" -o none
        ok "OS-level IP forwarding disabled on Hub1 NVA"
        impact "Hub1 NVA will not forward packets despite Azure NIC forwarding being on."
        impact "Connection Monitors: all paths through Hub1 NVA will FAIL."
    fi
}

# ── nva-stop-ssh ─────────────────────────────────────────────────────────────
do_nva_stop_ssh() {
    if $REVERT; then
        info "Re-starting SSH daemon on both NVA VMs"
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "systemctl start sshd || systemctl start ssh" -o none
        az vm run-command invoke -g "$RG" -n "$HUB2_NVA_VM" \
            --command-id RunShellScript \
            --scripts "systemctl start sshd || systemctl start ssh" -o none
        ok "SSH daemon re-started on both NVAs"
    else
        info "Stopping SSH daemon on both NVA VMs (${HUB1_NVA_VM}, ${HUB2_NVA_VM})"
        info "REASON: The LB health probe uses TCP:22 (SSH). Stopping sshd makes the LB mark both backends as unhealthy."
        az vm run-command invoke -g "$RG" -n "$HUB1_NVA_VM" \
            --command-id RunShellScript \
            --scripts "systemctl stop sshd || systemctl stop ssh" -o none
        az vm run-command invoke -g "$RG" -n "$HUB2_NVA_VM" \
            --command-id RunShellScript \
            --scripts "systemctl stop sshd || systemctl stop ssh" -o none
        ok "SSH daemon stopped on both NVAs"
        impact "LB health probes (TCP:22) will fail on both backends."
        impact "The LB will have no healthy backends — ALL traffic through the NVA will be black-holed."
        impact "Connection Monitors: ALL paths through both hubs will FAIL."
    fi
}

# ── nva-no-internet ──────────────────────────────────────────────────────────
do_nva_no_internet() {
    local HUB1_VNET_NAME="${PREFIX}-hub1-vnet"
    local NATGW_NAME="${PREFIX}-hub1-natgw"
    if $REVERT; then
        info "Re-associating NAT Gateway ${NATGW_NAME} with Hub1 NvaSubnet"
        az network vnet subnet update \
            -g "$RG" --vnet-name "$HUB1_VNET_NAME" -n "NvaSubnet" \
            --nat-gateway "$NATGW_NAME" -o none 2>/dev/null || true
        ok "NAT Gateway restored on Hub1 NvaSubnet"
    else
        info "Removing NAT Gateway from Hub1 NvaSubnet"
        info "REASON: Without NAT Gateway and with defaultOutboundAccess=false, NVAs lose all outbound internet. SNAT for spoke traffic fails."
        az network vnet subnet update \
            -g "$RG" --vnet-name "$HUB1_VNET_NAME" -n "NvaSubnet" \
            --remove natGateway -o none 2>/dev/null || true
        ok "NAT Gateway removed from Hub1 NvaSubnet"
        impact "NVAs in Hub1 cannot reach the internet — SNAT for spoke outbound traffic will fail."
        impact "Connection Monitors: spokes-to-internet test group will FAIL for Hub1 spokes."
    fi
}

# ── vpn-disconnect ───────────────────────────────────────────────────────────
do_vpn_disconnect() {
    if $REVERT; then
        local HUB1_GW="${PREFIX}-hub1-vpngw"
        local ONPREM_GW="${PREFIX}-onprem-vpngw"
        info "Re-creating VPN connection ${HUB1_VPN_CONN}"
        az network vpn-connection create \
            -g "$RG" -n "$HUB1_VPN_CONN" \
            --vnet-gateway1 "$HUB1_GW" --vnet-gateway2 "$ONPREM_GW" \
            --shared-key "$VPN_SHARED_KEY" \
            --enable-bgp -o none 2>/dev/null || \
        az network vpn-connection create \
            -g "$RG" -n "$HUB1_VPN_CONN" \
            --vnet-gateway1 "$HUB1_GW" --vnet-gateway2 "$ONPREM_GW" \
            --shared-key "$VPN_SHARED_KEY" -o none
        ok "VPN connection ${HUB1_VPN_CONN} re-created"
        info "Note: it may take a few minutes for the tunnel to come up."
    else
        info "Deleting VPN connection ${HUB1_VPN_CONN}"
        info "REASON: Simulates a VPN tunnel failure between hub1 and on-prem."
        az network vpn-connection delete -g "$RG" -n "$HUB1_VPN_CONN" -o none 2>/dev/null || \
            warn "Connection already absent — idempotent."
        ok "VPN connection ${HUB1_VPN_CONN} deleted"
        impact "On-prem connectivity via Hub1 is lost."
        impact "Connection Monitors: spoke11↔onprem, spoke12↔onprem will FAIL."
    fi
}

# ── bgp-propagation ──────────────────────────────────────────────────────────
do_bgp_propagation() {
    if $REVERT; then
        info "Disabling BGP route propagation on ${SPOKE11_RT} (restoring UDR-only routing)"
        az network route-table update -g "$RG" -n "$SPOKE11_RT" \
            --disable-bgp-route-propagation true -o none
        ok "BGP propagation disabled on spoke11 route table"
    else
        info "Enabling BGP route propagation on ${SPOKE11_RT}"
        info "REASON: BGP-learned routes may override UDRs, causing traffic to bypass the NVA."
        az network route-table update -g "$RG" -n "$SPOKE11_RT" \
            --disable-bgp-route-propagation false -o none
        ok "BGP propagation enabled on spoke11 route table"
        impact "Spoke11 may learn routes directly from VPN gateway, bypassing the NVA."
        impact "Connection Monitors: spoke11↔onprem may take an unexpected (unfiltered) path."
    fi
}

# ── gw-disable-bgp-propagation ──────────────────────────────────────────────
do_gw_disable_bgp_propagation() {
    if $REVERT; then
        info "Re-enabling BGP route propagation on ${HUB1_GW_RT} (restoring normal gateway routing)"
        az network route-table update -g "$RG" -n "$HUB1_GW_RT" \
            --disable-bgp-route-propagation false -o none
        ok "BGP propagation re-enabled on Hub1 GatewaySubnet route table"
    else
        info "Disabling BGP route propagation on ${HUB1_GW_RT}"
        info "REASON: Without BGP-learned routes the GatewaySubnet loses return paths to spoke"
        info "        and on-prem prefixes, breaking connectivity."
        az network route-table update -g "$RG" -n "$HUB1_GW_RT" \
            --disable-bgp-route-propagation true -o none
        ok "BGP propagation disabled on Hub1 GatewaySubnet route table"
        impact "The VPN gateway will not learn BGP routes from peers; return traffic to"
        impact "on-prem prefixes learned via BGP will be dropped."
        impact "Connection Monitors: spoke11↔onprem, spoke12↔onprem will FAIL."
    fi
}

# ── gateway-nsg ──────────────────────────────────────────────────────────────
do_gateway_nsg() {
    local GW_NSG="${PREFIX}-fault-gw-nsg"
    local GW_SUBNET="GatewaySubnet"
    if $REVERT; then
        info "Removing NSG from Hub1 GatewaySubnet"
        az network vnet subnet update \
            -g "$RG" --vnet-name "$HUB1_VNET" -n "$GW_SUBNET" \
            --network-security-group "" -o none 2>/dev/null || \
        az network vnet subnet update \
            -g "$RG" --vnet-name "$HUB1_VNET" -n "$GW_SUBNET" \
            --remove networkSecurityGroup -o none
        # Clean up the fault NSG
        az network nsg delete -g "$RG" -n "$GW_NSG" -o none 2>/dev/null || true
        ok "NSG removed from Hub1 GatewaySubnet"
    else
        info "Creating restrictive NSG and applying to Hub1 GatewaySubnet"
        info "REASON: NSGs on GatewaySubnet can break VPN/ExpressRoute gateway operation."
        az network nsg create -g "$RG" -n "$GW_NSG" -o none 2>/dev/null || true
        az network nsg rule create -g "$RG" --nsg-name "$GW_NSG" -n "DenyAll" \
            --priority 100 --direction Inbound --access Deny --protocol '*' \
            --source-address-prefixes '*' --destination-address-prefixes '*' \
            --source-port-ranges '*' --destination-port-ranges '*' -o none 2>/dev/null || true
        az network vnet subnet update \
            -g "$RG" --vnet-name "$HUB1_VNET" -n "$GW_SUBNET" \
            --network-security-group "$GW_NSG" -o none
        ok "Restrictive NSG applied to Hub1 GatewaySubnet"
        impact "VPN gateway control plane & data plane traffic will be blocked."
        impact "Connection Monitors: all on-prem paths through Hub1 will FAIL."
    fi
}

# ── peering-no-gateway-transit ────────────────────────────────────────────────
do_peering_no_gateway_transit() {
    if $REVERT; then
        info "Re-enabling AllowGatewayTransit on hub1→spoke11 peering"
        az network vnet peering update \
            -g "$RG" --vnet-name "$HUB1_VNET" -n "$HUB1_TO_SPOKE11_PEER" \
            --set allowGatewayTransit=true -o none
        ok "AllowGatewayTransit restored on hub1→spoke11 peering"
    else
        info "Disabling AllowGatewayTransit on hub1→spoke11 peering"
        info "REASON: Without AllowGatewayTransit the hub VPN gateway routes are not"
        info "        shared with spoke11, breaking on-prem↔spoke11 connectivity."
        az network vnet peering update \
            -g "$RG" --vnet-name "$HUB1_VNET" -n "$HUB1_TO_SPOKE11_PEER" \
            --set allowGatewayTransit=false -o none
        ok "AllowGatewayTransit disabled on hub1→spoke11 peering"
        impact "Spoke11 can no longer use the hub1 VPN gateway for on-prem connectivity."
        impact "Connection Monitors: spoke11↔onprem will FAIL."
    fi
}

# ── peering-no-use-remote-gw ─────────────────────────────────────────────────
do_peering_no_use_remote_gw() {
    if $REVERT; then
        info "Re-enabling UseRemoteGateways on spoke11→hub1 peering"
        az network vnet peering update \
            -g "$RG" --vnet-name "$SPOKE11_VNET" -n "$SPOKE11_TO_HUB1_PEER" \
            --set useRemoteGateways=true -o none
        ok "UseRemoteGateways restored on spoke11→hub1 peering"
    else
        info "Disabling UseRemoteGateways on spoke11→hub1 peering"
        info "REASON: Without UseRemoteGateways the spoke does not learn gateway routes"
        info "        (BGP or static), so on-prem↔spoke11 traffic is black-holed."
        az network vnet peering update \
            -g "$RG" --vnet-name "$SPOKE11_VNET" -n "$SPOKE11_TO_HUB1_PEER" \
            --set useRemoteGateways=false -o none
        ok "UseRemoteGateways disabled on spoke11→hub1 peering"
        impact "Spoke11 loses all routes learned from the hub1 VPN gateway."
        impact "Connection Monitors: spoke11↔onprem will FAIL."
    fi
}

# ── peering-disconnect ───────────────────────────────────────────────────────
do_peering_disconnect() {
    if $REVERT; then
        info "Re-creating VNet peering between hub1 and spoke11"
        local HUB1_ID SPOKE11_ID
        HUB1_ID=$(az network vnet show -g "$RG" -n "$HUB1_VNET" --query id -o tsv)
        SPOKE11_ID=$(az network vnet show -g "$RG" -n "$SPOKE11_VNET" --query id -o tsv)
        az network vnet peering create \
            -g "$RG" --vnet-name "$HUB1_VNET" -n "$HUB1_TO_SPOKE11_PEER" \
            --remote-vnet "$SPOKE11_ID" --allow-vnet-access --allow-forwarded-traffic \
            --allow-gateway-transit -o none 2>/dev/null || true
        az network vnet peering create \
            -g "$RG" --vnet-name "$SPOKE11_VNET" -n "$SPOKE11_TO_HUB1_PEER" \
            --remote-vnet "$HUB1_ID" --allow-vnet-access --allow-forwarded-traffic \
            --use-remote-gateways -o none 2>/dev/null || true
        ok "VNet peering between hub1 and spoke11 restored"
    else
        info "Deleting VNet peering between hub1 and spoke11"
        info "REASON: Without peering, spoke11 is completely disconnected from hub1."
        az network vnet peering delete \
            -g "$RG" --vnet-name "$HUB1_VNET" -n "$HUB1_TO_SPOKE11_PEER" -o none 2>/dev/null || true
        az network vnet peering delete \
            -g "$RG" --vnet-name "$SPOKE11_VNET" -n "$SPOKE11_TO_HUB1_PEER" -o none 2>/dev/null || true
        ok "VNet peering between hub1 and spoke11 deleted"
        impact "Spoke11 is completely disconnected from hub1 and the rest of the network."
        impact "Connection Monitors: ALL spoke11 paths will FAIL."
    fi
}

# ── multi-fault ──────────────────────────────────────────────────────────────
SINGLE_SCENARIOS=(
    ip-forwarding-hub1 ip-forwarding-hub2
    udr-wrong-nexthop udr-missing-route udr-detach
    nsg-block-icmp nsg-block-all nsg-block-ssh
    nva-iptables-drop nva-iptables-block-spoke nva-os-forwarding nva-stop-ssh nva-no-internet
    vpn-disconnect bgp-propagation gw-disable-bgp-propagation gateway-nsg
    peering-disconnect peering-no-gateway-transit peering-no-use-remote-gw
)

do_multi_fault() {
    local COUNT=$(( RANDOM % 2 + 2 ))  # 2 or 3
    if $REVERT; then
        info "Reverting ALL known faults (multi-fault revert)"
        for s in "${SINGLE_SCENARIOS[@]}"; do
            SCENARIO="$s" REVERT=true dispatch_scenario 2>/dev/null || true
        done
        ok "All faults reverted"
    else
        info "Injecting ${COUNT} random faults simultaneously"
        local SHUFFLED
        SHUFFLED=($(printf '%s\n' "${SINGLE_SCENARIOS[@]}" | shuf | head -n "$COUNT"))
        for s in "${SHUFFLED[@]}"; do
            echo ""
            info "━━━ Injecting fault: ${s} ━━━"
            SCENARIO="$s" REVERT=false dispatch_scenario
        done
        echo ""
        ok "Multi-fault injection complete (${COUNT} faults injected)"
    fi
}

###############################################################################
# Dispatcher
###############################################################################
dispatch_scenario() {
    case "${SCENARIO}" in
        ip-forwarding-hub1)       do_ip_forwarding_hub1 ;;
        ip-forwarding-hub2)       do_ip_forwarding_hub2 ;;
        udr-wrong-nexthop)        do_udr_wrong_nexthop ;;
        udr-missing-route)        do_udr_missing_route ;;
        udr-detach)               do_udr_detach ;;
        nsg-block-icmp)           do_nsg_block_icmp ;;
        nsg-block-all)            do_nsg_block_all ;;
        nsg-block-ssh)            do_nsg_block_ssh ;;
        nva-iptables-drop)        do_nva_iptables_drop ;;
        nva-iptables-block-spoke) do_nva_iptables_block_spoke ;;
        nva-os-forwarding)        do_nva_os_forwarding ;;
        nva-stop-ssh)             do_nva_stop_ssh ;;
        nva-no-internet)          do_nva_no_internet ;;
        vpn-disconnect)           do_vpn_disconnect ;;
        bgp-propagation)          do_bgp_propagation ;;
        gw-disable-bgp-propagation) do_gw_disable_bgp_propagation ;;
        gateway-nsg)              do_gateway_nsg ;;
        peering-disconnect)       do_peering_disconnect ;;
        peering-no-gateway-transit) do_peering_no_gateway_transit ;;
        peering-no-use-remote-gw) do_peering_no_use_remote_gw ;;
        multi-fault)              do_multi_fault ;;
        *) err "Unknown scenario: ${SCENARIO}"; usage ;;
    esac
}

###############################################################################
# Main
###############################################################################
echo ""
if $REVERT; then
    info "╔══════════════════════════════════════════════════════════╗"
    info "║  REVERTING FAULT: ${SCENARIO}"
    info "║  Resource Group:  ${RG}"
    info "║  Prefix:          ${PREFIX}"
    info "╚══════════════════════════════════════════════════════════╝"
else
    warn "╔══════════════════════════════════════════════════════════╗"
    warn "║  INJECTING FAULT: ${SCENARIO}"
    warn "║  Resource Group:  ${RG}"
    warn "║  Prefix:          ${PREFIX}"
    warn "╚══════════════════════════════════════════════════════════╝"
fi
echo ""

dispatch_scenario

echo ""
info "Done."
