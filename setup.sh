#!/usr/bin/env bash
set -euo pipefail

# GCP Billing Guard — automated setup
# Creates a dedicated project with a Cloud Function that disables billing
# on all managed projects when any budget threshold is exceeded.
#
# Usage:
#   ./setup.sh \
#     --guard-project-id my-billing-guard \
#     --guard-billing-account XXXXXX-XXXXXX-XXXXXX \
#     --managed-billing-accounts "AAAAAA-AAAAAA-AAAAAA,BBBBBB-BBBBBB-BBBBBB" \
#     --region us-central1 \
#     --threshold 1.0 \
#     --mode billing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
REGION="us-central1"
THRESHOLD="1.0"
GUARD_PROJECT_ID=""
GUARD_BILLING_ACCOUNT=""
MANAGED_BILLING_ACCOUNTS=""
ENFORCEMENT_MODE="billing"
VELOCITY_WINDOW="1800"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --guard-project-id ID          Project ID for the billing guard (will be created)
  --guard-billing-account ID     Billing account ID for the guard project (keep separate!)
  --managed-billing-accounts IDs Comma-separated billing account IDs to protect

Optional:
  --region REGION                GCP region (default: us-central1)
  --threshold FLOAT              Budget ratio to trigger at (default: 1.0 = 100%)
  --mode MODE                    "billing" (nuclear, default) or "api" (surgical)
  --velocity-window SECS         Spend avalanche detection window (default: 1800 = 30 min)
  --help                         Show this help

Enforcement modes:
  billing  Detach billing account. All services stop immediately.
           Use for: sandboxes, dev projects, hobby projects.

  api      Disable expensive APIs (compute, dataflow, vertex AI, etc.)
           Storage, auth, and networking stay online.
           Use for: production where uptime matters but you need cost control.

Example:
  ./setup.sh \\
    --guard-project-id billing-guard-123 \\
    --guard-billing-account XXXXXX-XXXXXX-XXXXXX \\
    --managed-billing-accounts "AAAAAA-AAAAAA-AAAAAA,BBBBBB-BBBBBB-BBBBBB" \\
    --mode api
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
    --mode) ENFORCEMENT_MODE="$2"; shift 2 ;;
    --velocity-window) VELOCITY_WINDOW="$2"; shift 2 ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$GUARD_PROJECT_ID" || -z "$GUARD_BILLING_ACCOUNT" || -z "$MANAGED_BILLING_ACCOUNTS" ]]; then
  echo "Error: --guard-project-id, --guard-billing-account, and --managed-billing-accounts are required."
  usage
fi

if [[ "$ENFORCEMENT_MODE" != "billing" && "$ENFORCEMENT_MODE" != "api" ]]; then
  echo "Error: --mode must be 'billing' or 'api'."
  exit 1
fi

echo "=== GCP Billing Guard Setup ==="
echo "Guard project:       $GUARD_PROJECT_ID"
echo "Guard billing:       $GUARD_BILLING_ACCOUNT"
echo "Managed accounts:    $MANAGED_BILLING_ACCOUNTS"
echo "Region:              $REGION"
echo "Threshold:           $THRESHOLD"
echo "Enforcement mode:    $ENFORCEMENT_MODE"
echo "Velocity window:     ${VELOCITY_WINDOW}s"
echo ""

if [[ "$ENFORCEMENT_MODE" == "billing" ]]; then
  echo "WARNING: 'billing' mode is the nuclear option."
  echo "  - ALL services in affected projects will stop immediately"
  echo "  - VMs receive SIGKILL, containers are terminated"
  echo "  - Data is frozen (not deleted) but may be purged if billing stays off"
  echo "  - Recovery requires manual re-linking and restarting all services"
  echo ""
  echo "  For production, consider --mode api instead."
  echo ""
  read -rp "Continue with 'billing' mode? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Step 1: Create the guard project
echo "[1/9] Creating project $GUARD_PROJECT_ID..."
if gcloud projects describe "$GUARD_PROJECT_ID" &>/dev/null; then
  echo "  Project already exists, skipping creation."
else
  gcloud projects create "$GUARD_PROJECT_ID" --name="Billing Guard"
fi

# Step 2: Link to its own billing account
echo "[2/9] Linking to billing account $GUARD_BILLING_ACCOUNT..."
gcloud billing projects link "$GUARD_PROJECT_ID" --billing-account="$GUARD_BILLING_ACCOUNT"

# Step 3: Enable required APIs (including Firestore for velocity detection)
echo "[3/9] Enabling APIs..."
gcloud services enable \
  cloudfunctions.googleapis.com \
  pubsub.googleapis.com \
  cloudbilling.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  eventarc.googleapis.com \
  artifactregistry.googleapis.com \
  firestore.googleapis.com \
  --project="$GUARD_PROJECT_ID"

# Step 4: Initialize Firestore (native mode) for velocity tracking
echo "[4/9] Initializing Firestore..."
if gcloud firestore databases describe --project="$GUARD_PROJECT_ID" &>/dev/null 2>&1; then
  echo "  Firestore already initialized."
else
  gcloud firestore databases create \
    --project="$GUARD_PROJECT_ID" \
    --location="$REGION" \
    --type=firestore-native \
    2>/dev/null || echo "  Firestore initialization skipped (may need manual setup)."
fi

# Step 5: Create Pub/Sub topic
echo "[5/9] Creating budget-alerts Pub/Sub topic..."
if gcloud pubsub topics describe budget-alerts --project="$GUARD_PROJECT_ID" &>/dev/null; then
  echo "  Topic already exists, skipping."
else
  for i in 1 2 3; do
    if gcloud pubsub topics create budget-alerts --project="$GUARD_PROJECT_ID" 2>/dev/null; then
      break
    fi
    echo "  Waiting for org policy propagation (attempt $i/3)..."
    sleep 30
  done
fi

# Step 6: Allow budget notifications to publish to the topic
echo "[6/9] Granting Pub/Sub publish access for budget notifications..."
gcloud pubsub topics add-iam-policy-binding budget-alerts \
  --project="$GUARD_PROJECT_ID" \
  --member="allAuthenticatedUsers" \
  --role="roles/pubsub.publisher" \
  --quiet

# Step 7: Deploy the Cloud Function
echo "[7/9] Deploying stopBilling function..."
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
  --set-env-vars="MANAGED_BILLING_ACCOUNTS=$MANAGED_BILLING_ACCOUNTS,BUDGET_THRESHOLD=$THRESHOLD,ENFORCEMENT_MODE=$ENFORCEMENT_MODE,VELOCITY_WINDOW_SECS=$VELOCITY_WINDOW"

# Step 8: Grant least-privilege IAM roles
echo "[8/9] Granting IAM roles to $SERVICE_ACCOUNT..."
IFS=',' read -ra ACCOUNTS <<< "$MANAGED_BILLING_ACCOUNTS"

for ACCOUNT_ID in "${ACCOUNTS[@]}"; do
  ACCOUNT_ID=$(echo "$ACCOUNT_ID" | tr -d ' ')
  echo "  Billing account $ACCOUNT_ID:"

  if [[ "$ENFORCEMENT_MODE" == "billing" ]]; then
    # billing.user on the billing account (billing.resourceAssociations.delete)
    echo "    + roles/billing.user (detach projects from billing)"
    gcloud billing accounts add-iam-policy-binding "$ACCOUNT_ID" \
      --member="serviceAccount:$SERVICE_ACCOUNT" \
      --role="roles/billing.user" \
      --quiet

    # billing.projectManager on each project under this billing account
    echo "    + roles/billing.projectManager on projects (deleteBillingAssignment)"
    PROJECT_LIST=$(gcloud billing projects list --billing-account="$ACCOUNT_ID" --format='value(projectId)' 2>/dev/null || true)
    for PROJECT_ID in $PROJECT_LIST; do
      if [[ "$PROJECT_ID" == "$GUARD_PROJECT_ID" ]]; then
        continue
      fi
      gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SERVICE_ACCOUNT" \
        --role="roles/billing.projectManager" \
        --quiet 2>/dev/null || echo "      Warning: could not grant on $PROJECT_ID"
    done
  else
    # API mode: need serviceusage.admin to disable APIs on target projects
    echo "    + roles/serviceusage.serviceUsageAdmin on projects (disable APIs)"
    PROJECT_LIST=$(gcloud billing projects list --billing-account="$ACCOUNT_ID" --format='value(projectId)' 2>/dev/null || true)
    for PROJECT_ID in $PROJECT_LIST; do
      if [[ "$PROJECT_ID" == "$GUARD_PROJECT_ID" ]]; then
        continue
      fi
      gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SERVICE_ACCOUNT" \
        --role="roles/serviceusage.serviceUsageAdmin" \
        --quiet 2>/dev/null || echo "      Warning: could not grant on $PROJECT_ID"
    done
  fi
done

# Step 9: Print summary and next steps
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Guard function deployed to: $GUARD_PROJECT_ID"
echo "Pub/Sub topic: projects/$GUARD_PROJECT_ID/topics/budget-alerts"
echo "Enforcement mode: $ENFORCEMENT_MODE"
echo "Velocity detection: ${VELOCITY_WINDOW}s window"
echo ""
echo "IMPORTANT: Set your budget target BELOW your actual spending limit."
echo "  GCP billing data can lag up to 24 hours. If your real limit is \$100,"
echo "  set your budget to \$50-75 to absorb latent charges after the kill switch fires."
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
  echo "  # Update each budget (add forecasted spend alerts too):"
  echo "  gcloud billing budgets update \"billingAccounts/$ACCOUNT_ID/budgets/BUDGET_ID\" \\"
  echo "    --notifications-rule-pubsub-topic=\"projects/$GUARD_PROJECT_ID/topics/budget-alerts\""
  echo ""
done
echo "Recommended budget thresholds: 50%, 80%, 90%, 100% (actual) + 50%, 90% (forecasted)"
echo ""
echo "To test:"
echo "  gcloud pubsub topics publish budget-alerts --project=$GUARD_PROJECT_ID \\"
echo "    --message='{\"budgetDisplayName\":\"test\",\"costAmount\":50,\"budgetAmount\":100,\"currencyCode\":\"USD\"}'"
echo ""
echo "  gcloud functions logs read stopBilling --project=$GUARD_PROJECT_ID --region=$REGION --limit=10"
