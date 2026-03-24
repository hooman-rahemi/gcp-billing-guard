# GCP Billing Guard

Automated billing kill switch for Google Cloud. Deploys a Cloud Function on a dedicated project that disables billing on all managed projects when any budget threshold is exceeded.

## Key design decision

The guard lives on its own billing account, separate from the projects it protects. This prevents the kill switch from being killed alongside the projects it's supposed to protect.

## Repo structure

```
function/          — Cloud Function source (Node.js)
setup.sh           — Automated setup script
.claude/skills/    — Claude Code skill for guided setup
```

## Usage

Run `/billing-guard` in Claude Code for guided setup, or run `./setup.sh` directly.
