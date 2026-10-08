#!/usr/bin/env bash
# Step 1.5 — AgentCore Memory resource with two long-term strategies.
#
#   Name: CustomerSupportMemory
#   Semantic extraction  customer_facts        cs_agent/{actorId}/facts
#   User preference      customer_preferences  cs_agent/{actorId}/preferences
#
# AWS calls that change something (1, skipped if the memory already exists):
#   1. bedrock-agentcore-control create-memory
#
# Waits until the memory is ACTIVE, then saves its ID (MEMORY_ID in main.py)
# to config.json.
#
# Usage:
#   ./setup_memory.sh            # apply
#   ./setup_memory.sh --dry-run  # print the payload, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$(dirname "$HERE")/config.json"

MEMORY_NAME="${MEMORY_NAME:-CustomerSupportMemory}"
EVENT_EXPIRY_DAYS="${EVENT_EXPIRY_DAYS:-90}"   # short-term events kept for 90 days (console default)
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

REGION="$(jq -r .region "$CONFIG")"
CP=(aws bedrock-agentcore-control --region "$REGION")

save_config() {  # save_config key value
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

STRATEGIES='[
  {"semanticMemoryStrategy": {
     "name": "customer_facts",
     "description": "Facts the customer shares, such as name, orders and issues",
     "namespaceTemplates": ["cs_agent/{actorId}/facts"]}},
  {"userPreferenceMemoryStrategy": {
     "name": "customer_preferences",
     "description": "Customer preferences, such as communication style and favourite products",
     "namespaceTemplates": ["cs_agent/{actorId}/preferences"]}}
]'

# Memory IDs are "<name>-<10 characters>".
MEMORY_ID="$("${CP[@]}" list-memories \
  --query "memories[?starts_with(id, '${MEMORY_NAME}-')].id | [0]" --output text)"
[[ "$MEMORY_ID" == "None" ]] && MEMORY_ID=""

echo "Region: $REGION"
echo "Memory: $MEMORY_NAME (${MEMORY_ID:-will be created}), event expiry $EVENT_EXPIRY_DAYS days"

if $DRY_RUN; then
  printf '\nStrategies:\n%s\n' "$(jq . <<< "$STRATEGIES")"
  echo; echo "Dry run only; no changes made."
  exit 0
fi

if [[ -z "$MEMORY_ID" ]]; then
  MEMORY_ID="$("${CP[@]}" create-memory \
    --name "$MEMORY_NAME" \
    --description "Long-term memory for the customer support agent" \
    --event-expiry-duration "$EVENT_EXPIRY_DAYS" \
    --memory-strategies "$STRATEGIES" \
    --query memory.id --output text)"
  echo "[1/1] Created memory $MEMORY_ID"
else
  echo "[1/1] Memory exists: $MEMORY_ID"
fi

# Strategies are provisioned in the background; this usually takes a few minutes.
for _ in $(seq 1 120); do
  STATUS="$("${CP[@]}" get-memory --memory-id "$MEMORY_ID" --query memory.status --output text)"
  [[ "$STATUS" == ACTIVE ]] && break
  [[ "$STATUS" == FAILED ]] && { echo "      Memory FAILED" >&2; exit 1; }
  sleep 10
done
echo "      Memory is $STATUS"
[[ "$STATUS" == ACTIVE ]] || { echo "Memory not ACTIVE yet; rerun this script later." >&2; exit 1; }

save_config memory_id "$MEMORY_ID"
save_config memory_arn "$("${CP[@]}" get-memory --memory-id "$MEMORY_ID" --query memory.arn --output text)"

echo
echo "Memory ID (MEMORY_ID in main.py): $MEMORY_ID"
echo "Saved to $CONFIG"
