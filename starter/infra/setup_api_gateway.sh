#!/usr/bin/env bash
# Step 1.3 A — expose the order-tracker Lambda through an API Gateway REST API.
#
# Builds every resource, GET method, Lambda proxy integration and operation
# name (the future MCP tool names) from order_tracker_openapi.json in a single
# API Gateway call, then grants the Lambda permission and deploys the stage.
#
# AWS calls that change something (3):
#   1. apigateway put-rest-api --mode overwrite  (or import-rest-api if the API does not exist yet)
#   2. lambda add-permission                     (skipped if the statement already exists)
#   3. apigateway create-deployment
#
# Usage:
#   ./setup_api_gateway.sh            # apply
#   ./setup_api_gateway.sh --dry-run  # render the OpenAPI body and print the plan, change nothing
#
# Override defaults with env vars: REGION, API_NAME, STAGE, FUNCTION.
set -euo pipefail

REGION="${REGION:-us-east-1}"
API_NAME="${API_NAME:-CustomerSupportAPI}"
STAGE="${STAGE:-prod}"
FUNCTION="${FUNCTION:-order-tracker}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

HERE="$(cd "$(dirname "$0")" && pwd)"

# ── Read-only lookups ─────────────────────────────────────────────────────────
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FUNCTION}"
API_ID="$(aws apigateway get-rest-apis --region "$REGION" \
  --query "items[?name=='${API_NAME}'].id | [0]" --output text)"
[[ "$API_ID" == "None" ]] && API_ID=""

BODY="$(mktemp -t order_tracker_openapi).json"
trap 'rm -f "$BODY"' EXIT
sed -e "s|__REGION__|${REGION}|g" -e "s|__ORDER_TRACKER_ARN__|${LAMBDA_ARN}|g" \
  "$HERE/order_tracker_openapi.json" > "$BODY"

echo "Account:  $ACCOUNT"
echo "Region:   $REGION"
echo "Lambda:   $LAMBDA_ARN"
echo "API:      $API_NAME (${API_ID:-will be created})"
echo "Stage:    $STAGE"

if $DRY_RUN; then
  echo
  echo "Rendered OpenAPI body:"
  cat "$BODY"
  echo
  echo "Dry run only; no changes made."
  exit 0
fi

# ── 1. Resources, methods, integrations and operation names ──────────────────
if [[ -z "$API_ID" ]]; then
  API_ID="$(aws apigateway import-rest-api --region "$REGION" \
    --parameters endpointConfigurationTypes=REGIONAL \
    --fail-on-warnings \
    --body "fileb://$BODY" \
    --query id --output text)"
  echo "[1/3] Imported new REST API $API_ID"
else
  aws apigateway put-rest-api --region "$REGION" \
    --rest-api-id "$API_ID" \
    --mode overwrite \
    --fail-on-warnings \
    --body "fileb://$BODY" > /dev/null
  echo "[1/3] Overwrote REST API $API_ID with the OpenAPI definition"
fi

# ── 2. Allow this API (any stage, any GET path) to invoke the Lambda ─────────
STATEMENT_ID="apigw-${API_ID}-get"
if ! err="$(aws lambda add-permission --region "$REGION" \
  --function-name "$FUNCTION" \
  --statement-id "$STATEMENT_ID" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/GET/*" \
  2>&1 >/dev/null)"; then
  if [[ "$err" == *ResourceConflictException* ]]; then
    echo "[2/3] Lambda permission $STATEMENT_ID already exists"
  else
    echo "$err" >&2
    exit 1
  fi
else
  echo "[2/3] Granted API Gateway permission to invoke $FUNCTION"
fi

# ── 3. Deploy to the stage ───────────────────────────────────────────────────
aws apigateway create-deployment --region "$REGION" \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE" \
  --description "order-tracker tools for AgentCore Gateway" > /dev/null
echo "[3/3] Deployed to stage $STAGE"

echo
echo "Invoke URL: https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE}"
