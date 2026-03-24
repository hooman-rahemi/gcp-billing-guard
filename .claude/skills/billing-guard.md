# Skill: billing-guard

Set up a GCP Billing Guard — a dedicated project with a Cloud Function that automatically disables billing on all managed projects when budget thresholds are exceeded.

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
3. Have a **separate** billing account for the guard project (so disabling billing on protected projects doesn't kill the guard)

## Setup flow

### Step 1: Gather information

Ask the user for:
1. **Guard project ID** — a globally unique GCP project ID for the guard (e.g., `billing-guard-acme`). Check if it already exists first.
2. **Guard billing account** — the billing account to use for the guard project itself. This MUST be different from the accounts being protected. List their accounts with `gcloud billing accounts list` to help them choose.
3. **Managed billing accounts** — comma-separated list of billing account IDs to protect. List with `gcloud billing accounts list`.
4. **Region** — default `us-central1`
5. **Threshold** — budget ratio to trigger at (default `1.0` = 100%)

### Step 2: Run setup

Run the setup script from the repo root:

```bash
./setup.sh \
  --guard-project-id <ID> \
  --guard-billing-account <GUARD_BILLING_ACCOUNT> \
  --managed-billing-accounts "<ACCOUNT1>,<ACCOUNT2>" \
  --region <REGION> \
  --threshold <THRESHOLD>
```

### Step 3: Point budgets to the guard

After the function is deployed, update each budget to publish to the guard's Pub/Sub topic.

For each managed billing account:
```bash
# List budgets
gcloud billing budgets list --billing-account=<ACCOUNT_ID>

# Update each budget
gcloud billing budgets update "billingAccounts/<ACCOUNT_ID>/budgets/<BUDGET_ID>" \
  --notifications-rule-pubsub-topic="projects/<GUARD_PROJECT_ID>/topics/budget-alerts"
```

If a billing account has no budget yet, create one:
```bash
gcloud billing budgets create \
  --billing-account=<ACCOUNT_ID> \
  --display-name="Monthly budget" \
  --budget-amount=<AMOUNT><CURRENCY> \
  --threshold-rule=percent=0.5,basis=current-spend \
  --threshold-rule=percent=0.8,basis=current-spend \
  --threshold-rule=percent=1.0,basis=current-spend \
  --notifications-rule-pubsub-topic="projects/<GUARD_PROJECT_ID>/topics/budget-alerts"
```

### Step 4: Verify

Test with a synthetic message:
```bash
gcloud pubsub topics publish budget-alerts --project=<GUARD_PROJECT_ID> \
  --message='{"budgetDisplayName":"test","costAmount":50,"budgetAmount":100,"currencyCode":"USD"}'

# Wait 15 seconds, then check logs
gcloud functions logs read stopBilling --project=<GUARD_PROJECT_ID> --region=<REGION> --limit=10
```

The logs should show the notification was parsed and show "No action" since 50 < 100.

## Adding a new billing account later

To add a new billing account to an existing guard:

1. Get the guard's service account:
```bash
gcloud functions describe stopBilling --project=<GUARD_PROJECT_ID> --region=<REGION> --format='value(serviceConfig.serviceAccountEmail)'
```

2. Grant it billing.admin on the new account:
```bash
gcloud billing accounts add-iam-policy-binding <NEW_ACCOUNT_ID> \
  --member="serviceAccount:<SA_EMAIL>" \
  --role="roles/billing.admin"
```

3. Update the function's env var:
```bash
gcloud functions deploy stopBilling \
  --project=<GUARD_PROJECT_ID> \
  --region=<REGION> \
  --gen2 \
  --update-env-vars="MANAGED_BILLING_ACCOUNTS=<OLD_ACCOUNTS>,<NEW_ACCOUNT_ID>"
```

4. Create/update budgets on the new account to publish to `projects/<GUARD_PROJECT_ID>/topics/budget-alerts`.

## Architecture

```
billing-guard project (separate billing account — pennies/month)
  └── Cloud Function: stopBilling (Node.js, 2nd gen, 256MB)
       └── Eventarc trigger on Pub/Sub topic: budget-alerts
            ↑
            ├── Billing Account A budget → publishes here
            ├── Billing Account B budget → publishes here
            └── Billing Account C budget → publishes here

When triggered:
  1. Parse budget notification from CloudEvent
  2. Check if cost/budget ratio exceeds threshold
  3. If yes: list all projects under the billing account
  4. Disable billing on each project (except the guard itself)
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Function not triggering | No Pub/Sub subscription | Redeploy the function with `--trigger-topic=budget-alerts` |
| "No message data" in logs | Wrong CloudEvent format | The function handles multiple formats; check if Eventarc trigger exists |
| "Missing costAmount" | Notification schema mismatch | Ensure budget uses `schemaVersion: 1.0` |
| "Failed to list projects" | Missing IAM permissions | Grant `billing.admin` to the function's SA on the billing account |
| Function killed with the rest | Guard on same billing account | The guard MUST be on a separate billing account |
