#!/usr/bin/env bash
# Step 1.3 B — create the AgentCore Gateway and its two targets.
#
#   B1/B2  CustomerSupportGateway, MCP protocol, NONE inbound authorizer
#   B3     API Gateway target  -> CustomerSupportAPI stage (3 GET operations)
#   B4     Lambda target       -> refund-processor, tool schema from lambda/lambda_schema
#   B5     Gateway URL (.../mcp) saved to config.json as cs_gateway_url
#
# Target names use hyphens (order-tracker, refund-processor) because the
# CreateGatewayTarget name pattern ([0-9a-zA-Z][-]?){1,100} rejects underscores.
#
# AWS calls that change something (5; the role and gateway are skipped if they
# already exist, existing targets are updated with update-gateway-target):
#   1. iam create-role            gateway service role trusted by bedrock-agentcore
#   2. iam put-role-policy        lambda:InvokeFunction on refund-processor only
#   3. create-gateway
#   4. create-gateway-target      API Gateway stage, no outbound auth
#   5. create-gateway-target      Lambda, GATEWAY_IAM_ROLE outbound auth
#
# Usage:
#   ./setup_agentcore_gateway.sh            # apply
#   ./setup_agentcore_gateway.sh --dry-run  # print the plan and payloads, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STARTER="$(dirname "$HERE")"
CONFIG="$STARTER/config.json"
SCHEMA="$STARTER/lambda/lambda_schema"

GATEWAY_NAME="${GATEWAY_NAME:-CustomerSupportGateway}"
ROLE_NAME="${ROLE_NAME:-CustomerSupportGatewayRole}"
API_NAME="${API_NAME:-CustomerSupportAPI}"
STAGE="${STAGE:-prod}"
ORDER_TARGET="order-tracker"
REFUND_TARGET="refund-processor"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

REGION="$(jq -r .region "$CONFIG")"
REFUND_LAMBDA_ARN="$(jq -r .lambda_refund_processor_arn "$CONFIG")"
CP=(aws bedrock-agentcore-control --region "$REGION")

save_config() {  # save_config key value
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

wait_ready() {  # wait_ready <description> <command that prints a status>
  local what="$1"; shift
  local status
  for _ in $(seq 1 60); do
    status="$("$@")"
    case "$status" in
      READY) echo "      $what is READY"; return 0 ;;
      FAILED|*UNSUCCESSFUL*) echo "      $what is $status" >&2; return 1 ;;
    esac
    sleep 5
  done
  echo "      Timed out waiting for $what (last status: $status)" >&2
  return 1
}

# ── Read-only lookups ─────────────────────────────────────────────────────────
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REST_API_ID="$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='${API_NAME}'].id | [0]" --output text)"
[[ "$REST_API_ID" == "None" ]] && { echo "REST API $API_NAME not found; run setup_api_gateway.sh first." >&2; exit 1; }

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
GATEWAY_ID="$("${CP[@]}" list-gateways --query "items[?name=='${GATEWAY_NAME}'].gatewayId | [0]" --output text)"
[[ "$GATEWAY_ID" == "None" ]] && GATEWAY_ID=""

TRUST_POLICY="$(jq -n --arg acct "$ACCOUNT" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "GatewayAssumeRolePolicy",
    Effect: "Allow",
    Principal: {Service: "bedrock-agentcore.amazonaws.com"},
    Action: "sts:AssumeRole",
    Condition: {StringEquals: {"aws:SourceAccount": $acct}}
  }]}')"

INVOKE_POLICY="$(jq -n --arg fn "$REFUND_LAMBDA_ARN" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "InvokeRefundProcessor",
    Effect: "Allow",
    Action: "lambda:InvokeFunction",
    Resource: $fn
  }]}')"

# Tool overrides give each order tool an agent-facing description; without
# them the gateway uses the bare operation name as the description.
ORDER_TARGET_CONFIG="$(jq -n --arg api "$REST_API_ID" --arg stage "$STAGE" \
  --slurpfile overrides "$HERE/order_tracker_tool_overrides.json" '{
  mcp: {apiGateway: {
    restApiId: $api,
    stage: $stage,
    apiGatewayToolConfiguration: {
      toolFilters: [
        {filterPath: "/orders/{order_id}",              methods: ["GET"]},
        {filterPath: "/customers/{customer_id}/orders", methods: ["GET"]},
        {filterPath: "/customers/{customer_id}",        methods: ["GET"]}
      ],
      toolOverrides: $overrides[0]
    }
  }}}')"

REFUND_TARGET_CONFIG="$(jq -n --arg fn "$REFUND_LAMBDA_ARN" --slurpfile tools "$SCHEMA" '{
  mcp: {lambda: {
    lambdaArn: $fn,
    toolSchema: {inlinePayload: $tools[0]}
  }}}')"

echo "Account:      $ACCOUNT ($REGION)"
echo "REST API:     $API_NAME ($REST_API_ID), stage $STAGE"
echo "Role:         $ROLE_NAME (${ROLE_ARN:-will be created})"
echo "Gateway:      $GATEWAY_NAME (${GATEWAY_ID:-will be created})"
echo "Refund tools: $(jq -r '[.[].name] | join(", ")' "$SCHEMA")"

if $DRY_RUN; then
  printf '\nTrust policy:\n%s\n\nRole policy:\n%s\n' "$TRUST_POLICY" "$INVOKE_POLICY"
  printf '\n%s target:\n%s\n\n%s target:\n%s\n' \
    "$ORDER_TARGET" "$ORDER_TARGET_CONFIG" "$REFUND_TARGET" "$REFUND_TARGET_CONFIG"
  echo; echo "Dry run only; no changes made."
  exit 0
fi

save_config api_gateway_rest_api_id "$REST_API_ID"
save_config api_gateway_stage "$STAGE"
save_config api_gateway_invoke_url "https://${REST_API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE}"

# ── 1-2. Gateway service role ─────────────────────────────────────────────────
if [[ -z "$ROLE_ARN" ]]; then
  ROLE_ARN="$(aws iam create-role --role-name "$ROLE_NAME" \
    --description "Service role for AgentCore Gateway $GATEWAY_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query Role.Arn --output text)"
  echo "[1/5] Created role $ROLE_ARN"
else
  echo "[1/5] Role exists: $ROLE_ARN"
fi
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name InvokeRefundProcessor \
  --policy-document "$INVOKE_POLICY"
echo "[2/5] Role policy InvokeRefundProcessor applied"
save_config cs_gateway_role_arn "$ROLE_ARN"

# ── 3. Gateway (B1, B2) ──────────────────────────────────────────────────────
if [[ -z "$GATEWAY_ID" ]]; then
  # A freshly created role can take a few seconds to become assumable.
  for attempt in 1 2 3 4 5 6; do
    if out="$("${CP[@]}" create-gateway \
        --name "$GATEWAY_NAME" \
        --description "Customer support agent tools (orders and refunds)" \
        --role-arn "$ROLE_ARN" \
        --protocol-type MCP \
        --authorizer-type NONE \
        --query gatewayId --output text 2>&1)"; then
      GATEWAY_ID="$out"; break
    fi
    if [[ "$out" == *"role"* && $attempt -lt 6 ]]; then
      echo "      Role not usable yet, retrying in 10s..."; sleep 10
    else
      echo "$out" >&2; exit 1
    fi
  done
  echo "[3/5] Created gateway $GATEWAY_ID"
else
  echo "[3/5] Gateway exists: $GATEWAY_ID"
fi
wait_ready "gateway" "${CP[@]}" get-gateway --gateway-identifier "$GATEWAY_ID" --query status --output text

read -r GATEWAY_ARN GATEWAY_URL < <("${CP[@]}" get-gateway --gateway-identifier "$GATEWAY_ID" \
  --query '[gatewayArn, gatewayUrl]' --output text)
save_config cs_gateway_name "$GATEWAY_NAME"
save_config cs_gateway_id "$GATEWAY_ID"
save_config cs_gateway_arn "$GATEWAY_ARN"
save_config cs_gateway_url "$GATEWAY_URL"   # B5: GATEWAY_URL for main.py

# ── 4-5. Targets (B3, B4) ────────────────────────────────────────────────────
create_target() {  # create_target <step> <name> <description> <config json> [credential json]
  local step="$1" name="$2" desc="$3" config="$4" creds="${5:-}" id args
  id="$("${CP[@]}" list-gateway-targets --gateway-identifier "$GATEWAY_ID" \
    --query "items[?name=='${name}'].targetId | [0]" --output text)"
  args=(--gateway-identifier "$GATEWAY_ID" --name "$name" --description "$desc"
    --target-configuration "$config")
  [[ -n "$creds" ]] && args+=(--credential-provider-configurations "$creds")
  if [[ "$id" == "None" ]]; then
    id="$("${CP[@]}" create-gateway-target "${args[@]}" --query targetId --output text)"
    echo "[$step/5] Created target $name ($id)"
  else
    # Re-apply the configuration so edits (e.g. tool descriptions) take effect.
    "${CP[@]}" update-gateway-target --target-id "$id" "${args[@]}" > /dev/null
    echo "[$step/5] Updated target $name ($id)"
  fi
  wait_ready "target $name" "${CP[@]}" get-gateway-target \
    --gateway-identifier "$GATEWAY_ID" --target-id "$id" --query status --output text
  save_config "cs_gateway_target_${name//-/_}_id" "$id"
}

# B3: API Gateway stage, no outbound authorization (methods use NONE auth).
create_target 4 "$ORDER_TARGET" "Order and customer lookup via $API_NAME/$STAGE" "$ORDER_TARGET_CONFIG"

# B4: Lambda target; Lambda targets only support the gateway service role.
create_target 5 "$REFUND_TARGET" "Refunds and return labels" "$REFUND_TARGET_CONFIG" \
  '[{"credentialProviderType": "GATEWAY_IAM_ROLE"}]'

echo
echo "Gateway URL (GATEWAY_URL in main.py): $GATEWAY_URL"
echo "Saved to $CONFIG"
