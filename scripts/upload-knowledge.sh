#!/usr/bin/env bash
# upload-knowledge.sh — Upload knowledge base files to the SRE Agent
#
# The SRE Agent knowledge base cannot be configured via Bicep.
# This script uploads all markdown files from the knowledge/ directory
# to the agent via the Azure SRE Agent REST API.
#
# Usage:
#   ./scripts/upload-knowledge.sh [--agent-name <name>] [--resource-group <rg>]
#
# Prerequisites:
#   - Azure CLI logged in with appropriate permissions
#   - SRE Agent already deployed
#   - jq installed

set -euo pipefail

# Defaults
AGENT_NAME="${AGENT_NAME:-netsre-sre-agent}"
RESOURCE_GROUP="${RESOURCE_GROUP:-netsre-rg}"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-$(dirname "$0")/../knowledge}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --knowledge-dir) KNOWLEDGE_DIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--agent-name NAME] [--resource-group RG] [--knowledge-dir DIR]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "========================================="
echo " SRE Agent Knowledge Base Upload"
echo "========================================="
echo "Agent:          $AGENT_NAME"
echo "Resource Group: $RESOURCE_GROUP"
echo "Knowledge Dir:  $KNOWLEDGE_DIR"
echo ""

# Verify knowledge directory exists
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "ERROR: Knowledge directory not found: $KNOWLEDGE_DIR"
  exit 1
fi

# Count files
FILE_COUNT=$(find "$KNOWLEDGE_DIR" -name "*.md" -type f | wc -l)
echo "Found $FILE_COUNT markdown file(s) to upload."
echo ""

if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "No markdown files found. Nothing to upload."
  exit 0
fi

# Get agent resource ID
echo "Looking up SRE Agent resource..."
AGENT_ID=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --query "id" -o tsv 2>/dev/null) || true

if [[ -z "$AGENT_ID" ]]; then
  echo "ERROR: SRE Agent '$AGENT_NAME' not found in resource group '$RESOURCE_GROUP'."
  echo ""
  echo "The SRE Agent knowledge base can also be uploaded via the portal:"
  echo "  1. Go to https://sre.azure.com"
  echo "  2. Select your agent"
  echo "  3. Navigate to Builder > Knowledge base"
  echo "  4. Click 'Upload files' and select the markdown files from: $KNOWLEDGE_DIR"
  echo ""
  echo "Supported formats: Markdown (.md), Text (.txt), PDF (.pdf), Word (.docx)"
  echo "Limits: Max 16MB per file, 1000 files per agent"
  exit 1
fi

echo "Agent ID: $AGENT_ID"
echo ""

# NOTE: As of July 2025, the SRE Agent knowledge base upload API is not
# publicly documented. The recommended approach is to use the portal UI.
# This script provides the portal instructions as a fallback.

echo "========================================="
echo " MANUAL UPLOAD REQUIRED"
echo "========================================="
echo ""
echo "The SRE Agent knowledge base must currently be uploaded via the portal UI."
echo "The REST API for knowledge base upload is not yet publicly available."
echo ""
echo "Steps:"
echo "  1. Go to https://sre.azure.com"
echo "  2. Select agent: $AGENT_NAME"
echo "  3. Navigate to: Builder > Knowledge base"
echo "  4. Click 'Upload files'"
echo "  5. Select all .md files from: $(cd "$KNOWLEDGE_DIR" && pwd)"
echo ""
echo "Files to upload:"
for f in "$KNOWLEDGE_DIR"/*.md; do
  if [[ -f "$f" ]]; then
    SIZE=$(wc -c < "$f")
    echo "  - $(basename "$f") ($(( SIZE / 1024 )) KB)"
  fi
done
echo ""
echo "After uploading, the agent will index the files and use them"
echo "as context when investigating networking incidents."
echo ""
echo "========================================="
echo " POST-UPLOAD CONFIGURATION"
echo "========================================="
echo ""
echo "After uploading knowledge files, configure the following in the portal:"
echo ""
echo "1. INCIDENT PLATFORM (auto-configured):"
echo "   Azure Monitor is connected by default. Connection Monitor failure"
echo "   alerts will automatically trigger the agent."
echo ""
echo "2. RESPONSE PLAN (recommended):"
echo "   Create a response plan for networking alerts:"
echo "   - Name: networking-incident-handler"
echo "   - Filter: Severity Sev0, Sev1, Sev2"
echo "   - Autonomy: Review (agent investigates, proposes actions)"
echo "   - Instructions: 'Check NVA IP forwarding, iptables rules, UDR configs,"
echo "     NSG rules, VPN connections, BGP propagation, NAT gateway, and peerings.'"
echo ""
echo "3. CONNECTORS (recommended):"
echo "   - Azure Monitor: Already connected (default)"
echo "   - Log Analytics: Connect to workspace '${AGENT_NAME%-sre-agent}-law'"
echo ""
echo "4. CUSTOM AGENTS (optional):"
echo "   For advanced scenarios, create networking sub-agents via"
echo "   Builder > Custom agents with specialized system prompts."
