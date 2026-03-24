# GCP Billing Guard

Automated billing kill switch for Google Cloud. Deploys a Cloud Function on a dedicated project that enforces spending limits across all your projects when budget thresholds are exceeded.

## The problem

GCP budget alerts are **informational only** — they don't stop spending. You have to build enforcement yourself. Getting this wrong is easy:

- Wrong CloudEvent format (1st gen vs 2nd gen)
- Missing Pub/Sub subscriptions (destroyed when billing is disabled)
- Guard on the same billing account as the projects it protects
- Empty message attributes (schema v1.0 doesn't include `billingAccountId`)
- Billing data can lag **up to 24 hours**, so a $100 budget can become a $500 bill before any alert fires

This repo handles all of these.

## How it works

```
billing-guard project (separate billing account — pennies/month)
  └── Cloud Function: stopBilling
       ├── Firestore: velocity tracking (spend avalanche detection)
       └── Pub/Sub topic: budget-alerts
            ↑
            ├── Budget A → exceeds threshold → enforce on all projects in Account A
            ├── Budget B → exceeds threshold → enforce on all projects in Account B
            └── Budget C → exceeds threshold → enforce on all projects in Account C
```

The guard lives on its **own billing account** so it survives when billing is disabled on your other projects.

## Two enforcement modes

| Mode | What it does | Use for |
|------|-------------|---------|
| `billing` (default) | Detaches billing account. **All services stop immediately.** | Sandboxes, dev, hobby projects |
| `api` | Disables expensive APIs (compute, dataflow, vertex AI). Storage, auth, networking stay online. | Production with uptime requirements |

## Spend avalanche detection

Static threshold alerts are vulnerable to sudden cost spikes. By the time billing data arrives (up to 24h lag), the damage is done.

The guard tracks the **velocity** of budget alerts using Firestore. If two consecutive threshold alerts arrive within a short window (default 30 min) with a large jump (default 30%+), it treats this as a spend avalanche — a leaked API key, a recursive loop, or a crypto-mining attack — and kills immediately, without waiting for the 100% threshold.

Example: if the 50% alert and 90% alert arrive 20 minutes apart, that's a 40% jump in 20 minutes. The guard fires immediately instead of waiting for 100%.

## Quick start

### With Claude Code

Run `/billing-guard` for guided setup.

### Manual setup

```bash
git clone https://github.com/hooman-rahemi/gcp-billing-guard.git
cd gcp-billing-guard

./setup.sh \
  --guard-project-id my-billing-guard \
  --guard-billing-account XXXXXX-XXXXXX-XXXXXX \
  --managed-billing-accounts "AAAAAA-AAAAAA-AAAAAA,BBBBBB-BBBBBB-BBBBBB" \
  --mode billing \
  --threshold 1.0
```

**Arguments:**

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--guard-project-id` | Yes | | Globally unique project ID for the guard |
| `--guard-billing-account` | Yes | | Billing account for the guard (must be separate!) |
| `--managed-billing-accounts` | Yes | | Comma-separated billing account IDs to protect |
| `--region` | No | `us-central1` | GCP region |
| `--threshold` | No | `1.0` | Budget ratio to trigger (1.0 = 100%) |
| `--mode` | No | `billing` | `billing` (nuclear) or `api` (surgical) |
| `--velocity-window` | No | `1800` | Avalanche detection window in seconds |

After setup, point your budgets to the guard's Pub/Sub topic:

```bash
gcloud billing budgets update "billingAccounts/ACCOUNT_ID/budgets/BUDGET_ID" \
  --notifications-rule-pubsub-topic="projects/my-billing-guard/topics/budget-alerts"
```

### Set your budget target BELOW your actual limit

GCP billing data can lag up to 24 hours. Charges continue accumulating in the telemetry pipeline even after the kill switch fires. If your real spending limit is $100, **set your budget to $50–75** to absorb the latent charges.

### Recommended budget thresholds

```bash
gcloud billing budgets create \
  --billing-account=ACCOUNT_ID \
  --display-name="Monthly budget" \
  --budget-amount=75USD \
  --threshold-rule=percent=0.5,basis=current-spend \
  --threshold-rule=percent=0.8,basis=current-spend \
  --threshold-rule=percent=0.9,basis=current-spend \
  --threshold-rule=percent=1.0,basis=current-spend \
  --threshold-rule=percent=0.5,basis=forecasted-spend \
  --threshold-rule=percent=0.9,basis=forecasted-spend \
  --notifications-rule-pubsub-topic="projects/my-billing-guard/topics/budget-alerts"
```

Use **forecasted spend** alerts alongside actual spend alerts. GCP's ML models can predict overruns before they happen based on your historical usage patterns.

## What happens when it fires

### `billing` mode (nuclear option)

When billing is detached from a project:

- **Compute Engine:** VMs receive SIGKILL and terminate immediately
- **GKE:** All pods and containers are dropped
- **Cloud Run / Functions:** Stop accepting requests
- **Dataflow / Dataproc:** Jobs abort, in-memory data is lost
- **Cloud Storage / BigQuery:** Data is frozen (not deleted), but inaccessible
- **Free tier resources:** Also shut down (collateral damage)

Data in storage is retained in a frozen state, but if billing remains off for an extended period, **Google reserves the right to permanently delete it**.

**Recovery** is manual: re-link billing, then manually restart VMs, re-deploy services, and verify data integrity. The control plane does not remember what was running.

**Use this mode for:** dev sandboxes, experiments, hobby projects, student accounts — anywhere total data loss is an acceptable trade-off for financial protection.

### `api` mode (surgical)

Disables specific expensive APIs while keeping core infrastructure alive:

| Disabled | Kept alive |
|----------|-----------|
| Compute Engine | Cloud Storage |
| Cloud Run | BigQuery (data access) |
| Cloud Functions | IAM / Auth |
| Dataflow | Networking |
| Vertex AI | Firestore |
| Dataproc | Secret Manager |

Custom list via `EXPENSIVE_APIS` env var.

**Use this mode for:** production environments where uptime matters but you need cost control.

## Adding a new billing account

```bash
SA=$(gcloud functions describe stopBilling --project=my-billing-guard \
  --region=us-central1 --format='value(serviceConfig.serviceAccountEmail)')

# For billing mode:
gcloud billing accounts add-iam-policy-binding NEW_ACCOUNT_ID \
  --member="serviceAccount:$SA" --role="roles/billing.user"

# For api mode:
gcloud projects add-iam-policy-binding NEW_PROJECT_ID \
  --member="serviceAccount:$SA" --role="roles/serviceusage.serviceUsageAdmin"

# Update managed accounts list
gcloud functions deploy stopBilling --project=my-billing-guard --region=us-central1 --gen2 \
  --update-env-vars="MANAGED_BILLING_ACCOUNTS=OLD_IDS,NEW_ACCOUNT_ID"
```

## IAM roles (least privilege)

The setup script grants only the minimum required permissions:

### `billing` mode

| Role | Level | Why |
|------|-------|-----|
| `roles/billing.user` | Billing Account | `billing.resourceAssociations.delete` — detach projects |
| `roles/billing.projectManager` | Each target Project | `resourcemanager.projects.deleteBillingAssignment` — sever link from project side |

### `api` mode

| Role | Level | Why |
|------|-------|-----|
| `roles/serviceusage.serviceUsageAdmin` | Each target Project | Disable specific APIs |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MANAGED_BILLING_ACCOUNTS` | (required) | Comma-separated billing account IDs |
| `BUDGET_THRESHOLD` | `1.0` | Ratio to trigger (1.0 = 100%) |
| `ENFORCEMENT_MODE` | `billing` | `billing` or `api` |
| `EXPENSIVE_APIS` | compute, dataflow, vertex AI, run, functions, dataproc | APIs to disable in `api` mode |
| `VELOCITY_WINDOW_SECS` | `1800` | Avalanche detection window (seconds) |
| `VELOCITY_MIN_JUMP` | `0.3` | Minimum threshold jump to trigger avalanche (0.3 = 30%) |

## Cost

The guard project costs nearly nothing:
- Cloud Function: free tier covers ~2M invocations/month
- Pub/Sub: free tier covers 10GB/month
- Firestore: free tier covers 50K reads + 20K writes/day
- Artifact Registry: minimal container storage

## License

MIT
