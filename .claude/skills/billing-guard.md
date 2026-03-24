# Skill: billing-guard

Set up a GCP Billing Guard — a dedicated project with a Cloud Function that automatically enforces spending limits on all managed projects when budget thresholds are exceeded.

## When to use

Use this skill when the user wants to:
- Set up billing protection for their GCP projects
- Create a billing kill switch
- Prevent GCP cost overruns
- Add a new billing account to an existing guard

## Prerequisites

The user must:
1. Be authenticated with `gcloud` (`gcloud auth login`)
2. Have Owner/Editor permissions on the billing accounts they want to protect
3. Have a **separate** billing account for the guard project

## Setup flow

### Step 1: Gather information

Ask the user for:
1. **Guard project ID** — globally unique GCP project ID (e.g., `billing-guard-acme`)
2. **Guard billing account** — MUST be different from the accounts being protected. List with `gcloud billing accounts list`.
3. **Managed billing accounts** — comma-separated list. List with `gcloud billing accounts list`.
4. **Enforcement mode:**
   - `billing` (default) — nuclear: detach billing, all services stop. For sandboxes/dev.
   - `api` — surgical: disable expensive APIs, keep storage/auth alive. For production.
5. **Region** — default `us-central1`
6. **Threshold** — default `1.0` (100%). Recommend setting budget target 25-50% below actual max due to billing latency.

### Step 2: Run setup

```bash
./setup.sh \
  --guard-project-id <ID> \
  --guard-billing-account <ACCOUNT> \
  --managed-billing-accounts "<ACCOUNT1>,<ACCOUNT2>" \
  --mode <billing|api> \
  --threshold <FLOAT>
```

### Step 3: Point budgets to the guard

Update each budget to publish to the guard's topic. Include both actual and forecasted spend thresholds:

```bash
gcloud billing budgets update "billingAccounts/<ACCOUNT>/budgets/<BUDGET_ID>" \
  --notifications-rule-pubsub-topic="projects/<GUARD_PROJECT>/topics/budget-alerts"
```

If no budget exists, create one with recommended thresholds:

```bash
gcloud billing budgets create \
  --billing-account=<ACCOUNT> \
  --display-name="Monthly budget" \
  --budget-amount=<AMOUNT><CURRENCY> \
  --threshold-rule=percent=0.5,basis=current-spend \
  --threshold-rule=percent=0.8,basis=current-spend \
  --threshold-rule=percent=0.9,basis=current-spend \
  --threshold-rule=percent=1.0,basis=current-spend \
  --threshold-rule=percent=0.5,basis=forecasted-spend \
  --threshold-rule=percent=0.9,basis=forecasted-spend \
  --notifications-rule-pubsub-topic="projects/<GUARD_PROJECT>/topics/budget-alerts"
```

IMPORTANT: Advise setting the budget amount 25-50% below the actual spending limit. GCP billing data lags up to 24 hours — charges continue accumulating after the kill switch fires.

### Step 4: Verify

```bash
gcloud pubsub topics publish budget-alerts --project=<GUARD_PROJECT> \
  --message='{"budgetDisplayName":"test","costAmount":50,"budgetAmount":100,"currencyCode":"USD"}'

sleep 15

gcloud functions logs read stopBilling --project=<GUARD_PROJECT> --region=<REGION> --limit=10
```

## Adding a new billing account

1. Get the guard's service account
2. Grant appropriate IAM role (billing.user for billing mode, serviceusage.serviceUsageAdmin for api mode)
3. Update the MANAGED_BILLING_ACCOUNTS env var on the function
4. Create/update budgets on the new account

## Key warnings

- **billing mode is destructive:** VMs get SIGKILL, data freezes, potential permanent deletion if billing stays off. Warn the user clearly.
- **Billing latency:** Up to 24h. Budget target should be well below actual max.
- **Guard must be on separate billing:** If the guard dies with the projects, it's useless.

## Architecture

```
billing-guard project (separate billing account)
  ├── Cloud Function: stopBilling
  ├── Firestore: velocity tracking (spend avalanche detection)
  └── Pub/Sub topic: budget-alerts
       ↑
       └── All budget alerts publish here

Two enforcement paths:
  billing mode: detach billing → all services stop
  api mode:     disable compute/dataflow/vertex AI → storage stays alive
```
