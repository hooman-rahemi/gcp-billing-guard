# GCP Billing Guard

Automated billing kill switch for Google Cloud. Deploys a Cloud Function on a dedicated project that enforces spending limits when budget thresholds are exceeded.

## Key design decisions

- The guard lives on its **own billing account**, separate from protected projects. Killing billing on protected projects cannot take down the kill switch.
- Two enforcement modes: `billing` (nuclear — detach billing) and `api` (surgical — disable expensive APIs only).
- Velocity-based spend avalanche detection using Firestore to catch sudden cost spikes before the 100% threshold.
- Least-privilege IAM: `billing.user` + `billing.projectManager` for billing mode, `serviceusage.serviceUsageAdmin` for api mode. Never `billing.admin`.

## Repo structure

```
function/          — Cloud Function source (Node.js)
setup.sh           — Automated setup script
.claude/skills/    — Claude Code skill for guided setup
```

## Usage

Run `/billing-guard` in Claude Code for guided setup, or run `./setup.sh` directly.
