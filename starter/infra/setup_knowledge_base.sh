#!/usr/bin/env bash
# Step 1.4 — Managed Knowledge Base over product_catalog.txt in S3.
#
#   1. Upload product_catalog.txt to an S3 bucket
#   2. Create Managed Knowledge Base CustomerSupportKB (managed embedding model,
#      new service role, S3 data source, default encryption)
#   3. Sync the data source and wait for it to finish
#   4. Save the Knowledge Base ID (KB_ID in main.py) to config.json
#
# AWS calls that change something (7, each skipped if the resource already exists;
# the upload and sync always run so the KB reflects the current catalog):
#   1. s3api create-bucket
#   2. s3 cp product_catalog.txt
#   3. iam create-role            KB service role trusted by bedrock.amazonaws.com
#   4. iam put-role-policy        s3:ListBucket / s3:GetObject on this bucket only
#   5. bedrock-agent create-knowledge-base   type MANAGED, embeddingModelType MANAGED
#   6. bedrock-agent create-data-source      managed S3 connector
#   7. bedrock-agent start-ingestion-job     the "Sync"
#
# Usage:
#   ./setup_knowledge_base.sh            # apply
#   ./setup_knowledge_base.sh --dry-run  # print the plan and payloads, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STARTER="$(dirname "$HERE")"
CONFIG="$STARTER/config.json"
CATALOG="$STARTER/product_catalog.txt"

KB_NAME="${KB_NAME:-CustomerSupportKB}"
ROLE_NAME="${ROLE_NAME:-CustomerSupportKBRole}"
DS_NAME="${DS_NAME:-product-catalog-s3}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

REGION="$(jq -r .region "$CONFIG")"
BA=(aws bedrock-agent --region "$REGION")

save_config() {  # save_config key value
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

wait_for() {  # wait_for <description> <done status> <command that prints a status>
  local what="$1" done="$2"; shift 2
  local status
  for _ in $(seq 1 120); do
    status="$("$@")"
    [[ "$status" == "$done" ]] && { echo "      $what is $status"; return 0; }
    [[ "$status" == FAILED || "$status" == *FAIL* || "$status" == STOPPED ]] && {
      echo "      $what is $status" >&2; return 1; }
    sleep 5
  done
  echo "      Timed out waiting for $what (last status: $status)" >&2
  return 1
}

# ── Read-only lookups ─────────────────────────────────────────────────────────
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-csai-kb-${ACCOUNT}-${REGION}}"
BUCKET_EXISTS=false
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null && BUCKET_EXISTS=true
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>/dev/null || true)"
KB_ID="$("${BA[@]}" list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" --output text)"
[[ "$KB_ID" == "None" ]] && KB_ID=""

TRUST_POLICY="$(jq -n --arg acct "$ACCOUNT" --arg region "$REGION" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: {Service: "bedrock.amazonaws.com"},
    Action: "sts:AssumeRole",
    Condition: {
      StringEquals: {"aws:SourceAccount": $acct},
      ArnLike: {"AWS:SourceArn": "arn:aws:bedrock:\($region):\($acct):knowledge-base/*"}
    }
  }]}')"

S3_POLICY="$(jq -n --arg acct "$ACCOUNT" --arg bucket "$BUCKET" '{
  Version: "2012-10-17",
  Statement: [
    {Sid: "S3ListBucketStatement", Effect: "Allow", Action: ["s3:ListBucket"],
     Resource: ["arn:aws:s3:::\($bucket)"],
     Condition: {StringEquals: {"aws:ResourceAccount": $acct}}},
    {Sid: "S3GetObjectStatement", Effect: "Allow", Action: ["s3:GetObject"],
     Resource: ["arn:aws:s3:::\($bucket)/*"],
     Condition: {StringEquals: {"aws:ResourceAccount": $acct}}}
  ]}')"

KB_CONFIG='{"type": "MANAGED", "managedKnowledgeBaseConfiguration": {"embeddingModelType": "MANAGED"}}'

DS_CONFIG="$(jq -n --arg bucket "$BUCKET" --arg acct "$ACCOUNT" '{
  type: "MANAGED_KNOWLEDGE_BASE_CONNECTOR",
  managedKnowledgeBaseConnectorConfiguration: {
    connectorParameters: {
      type: "S3",
      version: "1",
      connectionConfiguration: {bucketName: $bucket, bucketOwnerAccountId: $acct}
    }
  }}')"

echo "Account:     $ACCOUNT ($REGION)"
echo "Bucket:      s3://$BUCKET ($($BUCKET_EXISTS && echo exists || echo will be created))"
echo "Role:        $ROLE_NAME (${ROLE_ARN:-will be created})"
echo "KB:          $KB_NAME (${KB_ID:-will be created})"
echo "Data source: $DS_NAME"

if $DRY_RUN; then
  printf '\nTrust policy:\n%s\n\nS3 policy:\n%s\n' "$TRUST_POLICY" "$S3_POLICY"
  printf '\nKB configuration:\n%s\n\nData source configuration:\n%s\n' "$KB_CONFIG" "$DS_CONFIG"
  echo; echo "Dry run only; no changes made."
  exit 0
fi

# ── 1-2. Bucket and catalog upload ───────────────────────────────────────────
if ! $BUCKET_EXISTS; then
  # us-east-1 must not be sent a LocationConstraint; other Regions require one.
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" > /dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
  fi
  echo "[1/7] Created bucket s3://$BUCKET"
else
  echo "[1/7] Bucket exists: s3://$BUCKET"
fi
aws s3 cp "$CATALOG" "s3://$BUCKET/product_catalog.txt" --region "$REGION" --only-show-errors
echo "[2/7] Uploaded product_catalog.txt"
save_config kb_bucket_name "$BUCKET"
save_config kb_bucket_arn "arn:aws:s3:::$BUCKET"

# ── 3-4. Service role ────────────────────────────────────────────────────────
if [[ -z "$ROLE_ARN" ]]; then
  ROLE_ARN="$(aws iam create-role --role-name "$ROLE_NAME" \
    --description "Service role for managed Knowledge Base $KB_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query Role.Arn --output text)"
  echo "[3/7] Created role $ROLE_ARN"
else
  echo "[3/7] Role exists: $ROLE_ARN"
fi
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name ReadProductCatalogBucket --policy-document "$S3_POLICY"
echo "[4/7] Role policy ReadProductCatalogBucket applied"
save_config kb_role_arn "$ROLE_ARN"

# ── 5. Knowledge Base ────────────────────────────────────────────────────────
if [[ -z "$KB_ID" ]]; then
  # A freshly created role can take a few seconds to become assumable.
  for attempt in 1 2 3 4 5 6; do
    if out="$("${BA[@]}" create-knowledge-base \
        --name "$KB_NAME" \
        --description "Product catalog, return policy, loyalty program and order status definitions" \
        --role-arn "$ROLE_ARN" \
        --knowledge-base-configuration "$KB_CONFIG" \
        --query knowledgeBase.knowledgeBaseId --output text 2>&1)"; then
      KB_ID="$out"; break
    fi
    if [[ "$out" == *[Rr]ole* && $attempt -lt 6 ]]; then
      echo "      Role not usable yet, retrying in 10s..."; sleep 10
    else
      echo "$out" >&2; exit 1
    fi
  done
  echo "[5/7] Created knowledge base $KB_ID"
else
  echo "[5/7] Knowledge base exists: $KB_ID"
fi
wait_for "knowledge base" ACTIVE \
  "${BA[@]}" get-knowledge-base --knowledge-base-id "$KB_ID" --query knowledgeBase.status --output text
save_config kb_id "$KB_ID"
save_config kb_arn "$("${BA[@]}" get-knowledge-base --knowledge-base-id "$KB_ID" \
  --query knowledgeBase.knowledgeBaseArn --output text)"

# ── 6. Data source ───────────────────────────────────────────────────────────
DS_ID="$("${BA[@]}" list-data-sources --knowledge-base-id "$KB_ID" \
  --query "dataSourceSummaries[?name=='${DS_NAME}'].dataSourceId | [0]" --output text)"
if [[ "$DS_ID" == "None" ]]; then
  DS_ID="$("${BA[@]}" create-data-source \
    --knowledge-base-id "$KB_ID" \
    --name "$DS_NAME" \
    --description "product_catalog.txt in s3://$BUCKET" \
    --data-source-configuration "$DS_CONFIG" \
    --data-deletion-policy DELETE \
    --query dataSource.dataSourceId --output text)"
  echo "[6/7] Created data source $DS_ID"
else
  echo "[6/7] Data source exists: $DS_ID"
fi
wait_for "data source" AVAILABLE \
  "${BA[@]}" get-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --query dataSource.status --output text
save_config kb_data_source_id "$DS_ID"

# ── 7. Sync ──────────────────────────────────────────────────────────────────
JOB_ID="$("${BA[@]}" start-ingestion-job --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --query ingestionJob.ingestionJobId --output text)"
echo "[7/7] Started sync $JOB_ID"
wait_for "sync" COMPLETE \
  "${BA[@]}" get-ingestion-job --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --ingestion-job-id "$JOB_ID" --query ingestionJob.status --output text
"${BA[@]}" get-ingestion-job --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --ingestion-job-id "$JOB_ID" --query ingestionJob.statistics --output json

echo
echo "Knowledge Base ID (KB_ID in main.py): $KB_ID"
echo "Saved to $CONFIG"
