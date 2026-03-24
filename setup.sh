#!/usr/bin/env bash
set -euo pipefail

# GCP Billing Guard — automated setup
# Creates a dedicated project with a Cloud Function that disables billing
# on all managed projects when any budget threshold is exceeded.
#
# Usage:
#   ./setup.sh \
#     --guard-project-id my-billing-guard \
#     --guard-billing-account 018952-C9A3E1-14BCE3 \
#     --managed-billing-accounts "01F84A-83B1B7-3D80D6,0153CD-3369A1-85DD9C" \
#     --region us-central1 \
#     --threshold 1.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
REGION="us-central1"
THRESHOLD="1.0"
GUARD_PROJECT_ID=""
GUARD_BILLING_ACCOUNT=""
MANAGED_BILLING_ACCOUNTS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --guard-project-id ID          Project ID for the billing guard (will be created)
  --guard-billing-account ID     Billing account ID for the guard project (keep separate!)
  --managed-billing-accounts IDs Comma-separated billing account IDs to protect

Optional:
  --region REGION                GCP region (default: us-central1)
  --threshold FLOAT              Budget ratio threshold to trigger (default: 1.0 = 100%)
  --help                         Show this help

Example:
  ./setup.sh \\
    --guard-project-id billing-guard-123 \\
    --guard-billing-account 018952-AAAAAA-BBBBBB \\
    --managed-billing-accounts "01F84A-CCCCCC-DDDDDD,0153CD-EEEEEE-FFFFFF"
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --guard-project-id) GUARD_PROJECT_ID="$2"; shift 2 ;;
    --guard-billing-account) GUARD_BILLING_ACCOUNT="$2"; shift 2 ;;
    --managed-billing-accounts) MANAGED_BILLING_ACCOUNTS="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$GUARD_PROJECT_ID" || -z "$GUARD_BILLING_ACCOUNT" || -z "$MANAGED_BILLING_ACCOUNTS" ]]; then
  echo "Error: --guard-project-id, --guard-billing-account, and --managed-billing-accounts are required."
  usage
fi

echo "=== GCP Billing Guard Setup ==="
echo "Guard project:       $GUARD_PROJECT_ID"
echo "Guard billing:       $GUARD_BILLING_ACCOUNT"
echo "Managed accounts:    $MANAGED_BILLING_ACCOUNTS"
echo "Region:              $REGION"
echo "Threshold:           $THRESHOLD"
echo ""

# Step 1: Create the guard project
echo "[1/8] Creating project $GUARD_PROJECT_ID..."
if gcloud projects describe "$GUARD_PROJECT_ID" &>/dev/null; then
  echo "  Project already exists, skipping creation."
else
  gcloud projects create "$GUARD_PROJECT_ID" --name="Billing Guard"
fi

# Step 2: Link to its own billing account
echo "[2/8] Linking to billing account $GUARD_BILLING_ACCOUNT..."
gcloud billing projects link "$GUARD_PROJECT_ID" --billing-account="$GUARD_BILLING_ACCOUNT"

# Step 3: Enable required APIs
echo "[3/8] Enabling APIs..."
gcloud services enable \
  cloudfunctions.googleapis.com \
  pubsub.googleapis.com \
  cloudbilling.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  eventarc.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$GUARD_PROJECT_ID"

# Step 4: Create Pub/Sub topic
echo "[4/8] Creating budget-alerts Pub/Sub topic..."
if gcloud pubsub topics describe budget-alerts --project="$GUARD_PROJECT_ID" &>/dev/null; then
  echo "  Topic already exists, skipping."
else
  # New projects may need a moment for org policy propagation
  for i in 1 2 3; do
    if gcloud pubsub topics create budget-alerts --project="$GUARD_PROJECT_ID" 2>/dev/null; then
      break
    fi
    echo "  Waiting for org policy propagation (attempt $i/3)..."
    sleep 30
  done
fi

# Step 5: Allow budget notifications to publish to the topic
echo "[5/8] Granting Pub/Sub publish access for budget notifications..."
gcloud pubsub topics add-iam-policy-binding budget-alerts \
  --project="$GUARD_PROJECT_ID" \
  --member="allAuthenticatedUsers" \
  --role="roles/pubsub.publisher" \
  --quiet

# Step 6: Deploy the Cloud Function
echo "[6/8] Deploying stopBilling function..."
SERVICE_ACCOUNT_NUM=$(gcloud projects describe "$GUARD_PROJECT_ID" --format='value(projectNumber)')
SERVICE_ACCOUNT="${SERVICE_ACCOUNT_NUM}-compute@developer.gserviceaccount.com"

gcloud functions deploy stopBilling \
  --project="$GUARD_PROJECT_ID" \
  --region="$REGION" \
  --gen2 \
  --runtime=nodejs22 \
  --entry-point=stopBilling \
  --trigger-topic=budget-alerts \
  --source="$SCRIPT_DIR/function" \
  --memory=256MB \
  --timeout=60s \
  --set-env-vars="MANAGED_BILLING_ACCOUNTS=$MANAGED_BILLING_ACCOUNTS,BUDGET_THRESHOLD=$THRESHOLD"

# Step 7: Grant billing.admin on each managed billing account
echo "[7/8] Granting billing.admin to $SERVICE_ACCOUNT..."
IFS=',' read -ra ACCOUNTS <<< "$MANAGED_BILLING_ACCOUNTS"
for ACCOUNT_ID in "${ACCOUNTS[@]}"; do
  ACCOUNT_ID=$(echo "$ACCOUNT_ID" | tr -d ' ')
  echo "  Granting on $ACCOUNT_ID..."
  gcloud billing accounts add-iam-policy-binding "$ACCOUNT_ID" \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role="roles/billing.admin" \
    --quiet
done

# Step 8: Print instructions for pointing budgets
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Guard function deployed to: $GUARD_PROJECT_ID"
echo "Pub/Sub topic: projects/$GUARD_PROJECT_ID/topics/budget-alerts"
echo ""
echo "NEXT STEP: Point your budget alerts to this topic."
echo ""
echo "For each budget, run:"
echo ""
for ACCOUNT_ID in "${ACCOUNTS[@]}"; do
  ACCOUNT_ID=$(echo "$ACCOUNT_ID" | tr -d ' ')
  echo "  # List budgets for $ACCOUNT_ID:"
  echo "  gcloud billing budgets list --billing-account=$ACCOUNT_ID"
  echo ""
  echo "  # Update each budget:"
  echo "  gcloud billing budgets update \"billingAccounts/$ACCOUNT_ID/budgets/BUDGET_ID\" \\"
  echo "    --notifications-rule-pubsub-topic=\"projects/$GUARD_PROJECT_ID/topics/budget-alerts\""
  echo ""
done
echo "Or use the --update-budgets flag (coming soon) to do this automatically."
echo ""
echo "To test:"
echo "  gcloud pubsub topics publish budget-alerts --project=$GUARD_PROJECT_ID \\"
echo "    --message='{\"budgetDisplayName\":\"test\",\"costAmount\":50,\"budgetAmount\":100,\"currencyCode\":\"USD\"}'"
echo ""
echo "  gcloud functions logs read stopBilling --project=$GUARD_PROJECT_ID --region=$REGION --limit=10"
