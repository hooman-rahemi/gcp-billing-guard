# GCP Billing Guard

A kill switch for Google Cloud billing. Automatically disables billing on all your projects when budget thresholds are exceeded.

## The problem

GCP budget alerts are **informational only** — they don't actually stop spending. You have to build the enforcement yourself. Getting this wrong (wrong event format, missing Pub/Sub subscription, guard on the same billing account as the projects it protects) means your "safety net" silently fails while costs run up.

## How it works

```
billing-guard project (separate billing account)
  └── Cloud Function: stopBilling
       └── Pub/Sub topic: budget-alerts
            ↑
            ├── Budget A → "cost exceeded" → disables billing on all projects in Account A
            ├── Budget B → "cost exceeded" → disables billing on all projects in Account B
            └── Budget C → "cost exceeded" → disables billing on all projects in Account C
```

The guard lives on its **own billing account** so it can't be killed alongside the projects it protects.

When any budget exceeds 100%, the function:
1. Parses the budget notification
2. Lists all projects under that billing account
3. Disables billing on each one (except the guard project itself)

## Quick start

### With Claude Code

If you use [Claude Code](https://claude.ai/code), run the `/billing-guard` skill for guided setup.

### Manual setup

```bash
git clone https://github.com/hoomanrahemi/gcp-billing-guard.git
cd gcp-billing-guard

./setup.sh \
  --guard-project-id my-billing-guard \
  --guard-billing-account 018952-AAAAAA-BBBBBB \
  --managed-billing-accounts "01F84A-CCCCCC-DDDDDD,0153CD-EEEEEE-FFFFFF" \
  --region us-central1 \
  --threshold 1.0
```

**Arguments:**

| Flag | Required | Description |
|------|----------|-------------|
| `--guard-project-id` | Yes | Globally unique project ID for the guard |
| `--guard-billing-account` | Yes | Billing account for the guard itself (must be separate!) |
| `--managed-billing-accounts` | Yes | Comma-separated billing account IDs to protect |
| `--region` | No | GCP region (default: `us-central1`) |
| `--threshold` | No | Budget ratio to trigger at (default: `1.0` = 100%) |

After setup, point your budgets to the guard's Pub/Sub topic:

```bash
gcloud billing budgets update "billingAccounts/ACCOUNT_ID/budgets/BUDGET_ID" \
  --notifications-rule-pubsub-topic="projects/my-billing-guard/topics/budget-alerts"
```

### Verify it works

```bash
# Send a test message (under budget — should log "No action")
gcloud pubsub topics publish budget-alerts --project=my-billing-guard \
  --message='{"budgetDisplayName":"test","costAmount":50,"budgetAmount":100,"currencyCode":"USD"}'

# Check logs
gcloud functions logs read stopBilling --project=my-billing-guard --region=us-central1 --limit=10
```

## Adding a new billing account

```bash
# Get the guard's service account
SA=$(gcloud functions describe stopBilling --project=my-billing-guard \
  --region=us-central1 --format='value(serviceConfig.serviceAccountEmail)')

# Grant it billing.admin
gcloud billing accounts add-iam-policy-binding NEW_ACCOUNT_ID \
  --member="serviceAccount:$SA" --role="roles/billing.admin"

# Update the managed accounts list
gcloud functions deploy stopBilling --project=my-billing-guard --region=us-central1 --gen2 \
  --update-env-vars="MANAGED_BILLING_ACCOUNTS=OLD_IDS,NEW_ACCOUNT_ID"
```

Then create/update budgets on the new account to publish to `projects/my-billing-guard/topics/budget-alerts`.

## Why this exists

GCP's budget + Pub/Sub + Cloud Function pattern is [well documented](https://cloud.google.com/billing/docs/how-to/notify), but easy to get wrong:

- **Wrong event format:** 2nd gen Cloud Functions receive CloudEvents, not raw Pub/Sub messages. Most tutorials show 1st gen code.
- **Missing subscriptions:** Disabling billing on a project can destroy the Pub/Sub subscription that the Eventarc trigger created, orphaning the trigger.
- **Guard on the same billing account:** If the guard function runs in a project on the billing account it's supposed to disable, killing billing kills the guard too.
- **Empty attributes:** Budget notifications (schema v1.0) don't include `billingAccountId` in Pub/Sub message attributes, despite what some docs suggest.

This repo handles all of these edge cases.

## Cost

The guard project costs nearly nothing:
- Cloud Function: free tier covers ~2M invocations/month
- Pub/Sub: free tier covers 10GB/month
- Artifact Registry: minimal storage for the function container

## License

MIT
