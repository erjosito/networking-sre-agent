#!/usr/bin/env bash
#
# clear-incidents.sh — Delete Azure SRE Agent incidents / threads (bash).
#
# Lists and deletes SRE Agent incident *threads* via the agent data-plane API
# (DELETE /api/v1/threads/{id}). The SRE Agent dedups / merges new alert firings
# into an existing open incident for the *same* alert rule, so a stale
# (acknowledged/resolved) incident swallows a fresh firing instead of opening a
# new investigation. Clearing the stale incidents lets the next fault injection
# open a clean incident.
#
# By default the onboarding thread (no incidentId) is preserved; use --all to
# delete it too.
#
# Requires: az (logged in), curl, jq.
#
# Usage:
#   ./clear-incidents.sh [options]
#
# Options:
#   -c, --config PATH          Manifest for defaults (default: ../sre-agent-config/config.yaml)
#   -n, --agent-name NAME      SRE Agent resource name (default: config agent.name)
#   -g, --resource-group RG    Agent resource group (default: config agent.resourceGroup)
#   -t, --title-contains STR   Only threads whose title contains STR (case-insensitive)
#   -i, --id ID                Delete this exact thread ID (repeatable; bypasses filters)
#   -s, --status STATUS        Only threads with this incident status (new/acknowledged/resolved)
#       --all                  Include the onboarding thread (no incidentId)
#   -l, --list-only            List matching threads and exit
#   -y, --yes                  Delete without the confirmation prompt
#   -h, --help                 Show this help and exit
#
# Examples:
#   ./clear-incidents.sh --list-only
#   ./clear-incidents.sh --title-contains clab --yes
#   ./clear-incidents.sh --status acknowledged
#   ./clear-incidents.sh --id 5a456a03-c837-4e93-9c29-f91f9e45048d
#   ./clear-incidents.sh --all --yes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../sre-agent-config/config.yaml"
DATA_PLANE_RESOURCE="https://azuresre.dev"

AGENT_NAME=""
RESOURCE_GROUP=""
TITLE_CONTAINS=""
STATUS_FILTER=""
IDS=()
ALL=false
LIST_ONLY=false
ASSUME_YES=false

info() { printf '\033[36m[INFO]   %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m[OK]     %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[WARN]   %s\033[0m\n' "$*"; }
err()  { printf '\033[31m[ERROR]  %s\033[0m\n' "$*" >&2; }

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)          CONFIG_FILE="$2"; shift 2 ;;
        -n|--agent-name)      AGENT_NAME="$2"; shift 2 ;;
        -g|--resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
        -t|--title-contains)  TITLE_CONTAINS="$2"; shift 2 ;;
        -i|--id)              IDS+=("$2"); shift 2 ;;
        -s|--status)          STATUS_FILTER="$2"; shift 2 ;;
        --all)                ALL=true; shift ;;
        -l|--list-only)       LIST_ONLY=true; shift ;;
        -y|--yes|--force)     ASSUME_YES=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

for tool in az curl jq; do
    command -v "$tool" >/dev/null 2>&1 || { err "Required tool not found: $tool"; exit 1; }
done

# ── Resolve AgentName / ResourceGroup from the manifest if not supplied ──────
if [[ ( -z "$AGENT_NAME" || -z "$RESOURCE_GROUP" ) && -f "$CONFIG_FILE" ]]; then
    # Read the two scalars under the top-level `agent:` block.
    while IFS= read -r line; do
        if [[ "$line" =~ ^agent:[[:space:]]*$ ]]; then in_agent=1; continue; fi
        if [[ "${in_agent:-0}" == "1" ]]; then
            [[ "$line" =~ ^[^[:space:]] ]] && break   # dedented → left the block
            if [[ -z "$AGENT_NAME"     && "$line" =~ ^[[:space:]]+name:[[:space:]]*([^[:space:]]+) ]]; then AGENT_NAME="${BASH_REMATCH[1]}"; fi
            if [[ -z "$RESOURCE_GROUP" && "$line" =~ ^[[:space:]]+resourceGroup:[[:space:]]*([^[:space:]]+) ]]; then RESOURCE_GROUP="${BASH_REMATCH[1]}"; fi
        fi
    done < "$CONFIG_FILE"
fi
[[ -n "$AGENT_NAME" ]]     || { err "AgentName not provided and not found in $CONFIG_FILE"; exit 1; }
[[ -n "$RESOURCE_GROUP" ]] || { err "ResourceGroup not provided and not found in $CONFIG_FILE"; exit 1; }

echo "========================================="
echo " SRE Agent — Clear Incidents"
echo "========================================="
info "Agent:          $AGENT_NAME"
info "Resource Group: $RESOURCE_GROUP"

# ── Resolve agent endpoint (control plane) ───────────────────────────────────
# Query agentEndpoint directly with -g/-n (avoids passing a leading-'/' resource
# ID to --ids, which some shells, e.g. Git Bash/MSYS, mangle into a Windows path).
ENDPOINT="$(az resource show -g "$RESOURCE_GROUP" --resource-type "Microsoft.App/agents" -n "$AGENT_NAME" --query "properties.agentEndpoint" -o tsv 2>/dev/null | tr -d '\r' || true)"
[[ -n "$ENDPOINT" ]] || { err "Agent '$AGENT_NAME' not found in '$RESOURCE_GROUP', or it has no agentEndpoint."; exit 1; }
info "Endpoint:       $ENDPOINT"

# ── Data-plane token ─────────────────────────────────────────────────────────
TOKEN="$(az account get-access-token --resource "$DATA_PLANE_RESOURCE" --query accessToken -o tsv 2>/dev/null | tr -d '\r' || true)"
[[ -n "$TOKEN" ]] || { err "Failed to acquire data-plane token for $DATA_PLANE_RESOURCE (run 'az login')."; exit 1; }

# ── List threads ─────────────────────────────────────────────────────────────
THREADS_JSON="$(curl -sf -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" "$ENDPOINT/api/v1/threads" || true)"
[[ -n "$THREADS_JSON" ]] || { err "Failed to list threads."; exit 1; }
TOTAL="$(echo "$THREADS_JSON" | jq '.value | length')"
if [[ "$TOTAL" -eq 0 ]]; then ok "No threads found — nothing to delete."; exit 0; fi

# ── Select targets (jq) ──────────────────────────────────────────────────────
# Each row: "<id>\t<incidentStatus|onboarding>\t<title>"
if [[ ${#IDS[@]} -gt 0 ]]; then
    ID_JSON="$(printf '%s\n' "${IDS[@]}" | jq -R . | jq -s .)"
    ROWS="$(echo "$THREADS_JSON" | jq -r --argjson ids "$ID_JSON" '
        .value[] | select(.id as $x | $ids | index($x))
        | [.id, ((.status.incidentStatus.status // "") | if . == "" then "onboarding" else . end), (.title // "")] | @tsv')"
else
    TC="$(printf '%s' "$TITLE_CONTAINS" | tr '[:upper:]' '[:lower:]')"
    ROWS="$(echo "$THREADS_JSON" | jq -r \
        --arg tc "$TC" --arg st "$STATUS_FILTER" --argjson all "$ALL" '
        .value[]
        | select($all or (.source == "Incident"))
        | select($tc == "" or ((.title // "") | ascii_downcase | contains($tc)))
        | select($st == "" or (.status.incidentStatus.status == $st))
        | [.id, ((.status.incidentStatus.status // "") | if . == "" then "onboarding" else . end), (.title // "")] | @tsv')"
fi

MATCHED=0
if [[ -n "$ROWS" ]]; then MATCHED="$(printf '%s\n' "$ROWS" | grep -c . || true)"; fi

echo ""
info "Matched $MATCHED of $TOTAL thread(s):"
if [[ -n "$ROWS" ]]; then
    while IFS=$'\t' read -r id st title; do
        printf '  - %s  [%s]  %s\n' "$id" "$st" "$title"
    done <<< "$ROWS"
fi
if [[ "$MATCHED" -eq 0 ]]; then ok "Nothing matches the given filters."; exit 0; fi
if [[ "$LIST_ONLY" == true ]]; then info "--list-only specified — not deleting."; exit 0; fi

# ── Confirm ──────────────────────────────────────────────────────────────────
if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "Delete these $MATCHED incident(s)? [y/N] " ans
    case "$ans" in y|Y|yes|YES) ;; *) warn "Aborted."; exit 0 ;; esac
fi

# ── Delete ───────────────────────────────────────────────────────────────────
DELETED=0; FAILED=0
while IFS=$'\t' read -r id st title; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
        "$ENDPOINT/api/v1/threads/$id" || true)"
    if [[ "$code" == "204" || "$code" == "200" ]]; then
        ok "Deleted $id"; DELETED=$((DELETED+1))
    else
        err "Failed to delete $id (HTTP $code)"; FAILED=$((FAILED+1))
    fi
done <<< "$ROWS"

echo ""
info "Done. Deleted $DELETED, failed $FAILED."
[[ "$FAILED" -eq 0 ]]
