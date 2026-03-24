const { GoogleAuth } = require("google-auth-library");
const { Firestore } = require("@google-cloud/firestore");

const BILLING_API = "https://cloudbilling.googleapis.com/v1";
const SERVICE_USAGE_API = "https://serviceusage.googleapis.com/v1";
const GUARD_PROJECT_ID = process.env.GOOGLE_CLOUD_PROJECT;

// Budget ratio threshold to trigger the kill switch (default: 1.0 = 100%).
// Set this BELOW your actual max to absorb billing latency (up to 24h).
// e.g. if your real limit is $100, set budget to $75 and threshold to 1.0.
const BUDGET_THRESHOLD = parseFloat(process.env.BUDGET_THRESHOLD || "1.0");

// Enforcement mode:
//   "billing"  — nuclear option: detach billing account (all services stop)
//   "api"      — surgical: disable specific expensive APIs, keep storage/auth alive
const ENFORCEMENT_MODE = process.env.ENFORCEMENT_MODE || "billing";

// APIs to disable in "api" mode. Override via env var (comma-separated).
const EXPENSIVE_APIS = (
  process.env.EXPENSIVE_APIS ||
  "compute.googleapis.com,dataflow.googleapis.com,aiplatform.googleapis.com,run.googleapis.com,cloudfunctions.googleapis.com,dataproc.googleapis.com"
)
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

// Comma-separated list of billing account IDs this guard manages.
const MANAGED_BILLING_ACCOUNTS = (process.env.MANAGED_BILLING_ACCOUNTS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

// Velocity detection: if two consecutive threshold alerts arrive within this
// many seconds, treat it as a spend avalanche and kill immediately regardless
// of whether the budget threshold has been reached.
const VELOCITY_WINDOW_SECS = parseInt(
  process.env.VELOCITY_WINDOW_SECS || "1800",
  10
); // default 30 min

// Minimum threshold gap to trigger velocity detection (e.g. 0.3 = 30% jump).
const VELOCITY_MIN_JUMP = parseFloat(process.env.VELOCITY_MIN_JUMP || "0.3");

const auth = new GoogleAuth({
  scopes: [
    "https://www.googleapis.com/auth/cloud-billing",
    "https://www.googleapis.com/auth/cloud-platform",
  ],
});

const firestore = new Firestore({ projectId: GUARD_PROJECT_ID });
const alertsCollection = firestore.collection("budget-alerts");

// ── Billing API helpers ──

async function listProjects(billingAccount) {
  const client = await auth.getClient();
  const res = await client.request({
    url: `${BILLING_API}/${billingAccount}/projects`,
    method: "GET",
  });
  return res.data.projectBillingInfo || [];
}

async function disableBilling(projectName) {
  const client = await auth.getClient();
  const res = await client.request({
    url: `${BILLING_API}/${projectName}`,
    method: "PUT",
    data: { billingAccountName: "" },
  });
  return res.data;
}

// ── Service Usage API helpers (surgical mode) ──

async function disableApi(projectId, apiName) {
  const client = await auth.getClient();
  const res = await client.request({
    url: `${SERVICE_USAGE_API}/projects/${projectId}/services/${apiName}:disable`,
    method: "POST",
    data: { disableDependentServices: false },
  });
  return res.data;
}

// ── Event parsing ──

function extractBase64Data(cloudEvent) {
  const d = cloudEvent.data;
  if (!d) return null;
  if (d.message && d.message.data) return d.message.data;
  if (typeof d.data === "string") return d.data;
  if (typeof d === "string") return d;
  return null;
}

// ── Velocity detection ──

async function detectVelocityAnomaly(budgetId, currentRatio) {
  const docRef = alertsCollection.doc(budgetId);

  try {
    const doc = await docRef.get();
    const now = Date.now();

    if (doc.exists) {
      const prev = doc.data();
      const elapsed = (now - prev.timestamp) / 1000;
      const jump = currentRatio - prev.ratio;

      console.log(
        `Velocity check: ${(jump * 100).toFixed(1)}% jump in ${elapsed.toFixed(0)}s (window: ${VELOCITY_WINDOW_SECS}s, min jump: ${(VELOCITY_MIN_JUMP * 100).toFixed(0)}%)`
      );

      // Update state for next check
      await docRef.set({ timestamp: now, ratio: currentRatio });

      if (elapsed <= VELOCITY_WINDOW_SECS && jump >= VELOCITY_MIN_JUMP) {
        console.log(
          `SPEND AVALANCHE DETECTED: ${(jump * 100).toFixed(1)}% increase in ${elapsed.toFixed(0)}s`
        );
        return true;
      }
    } else {
      // First alert for this budget — record and continue
      await docRef.set({ timestamp: now, ratio: currentRatio });
    }
  } catch (err) {
    // Firestore failure should not prevent the threshold-based kill switch
    console.error("Velocity check failed (non-fatal):", err.message);
  }

  return false;
}

// ── Enforcement ──

async function enforceOnProject(projectId) {
  if (ENFORCEMENT_MODE === "api") {
    console.log(
      `[API mode] Disabling expensive APIs on ${projectId}: ${EXPENSIVE_APIS.join(", ")}`
    );
    for (const api of EXPENSIVE_APIS) {
      try {
        await disableApi(projectId, api);
        console.log(`  Disabled ${api} on ${projectId}`);
      } catch (err) {
        // API might not be enabled — that's fine
        const msg =
          err.response?.data?.error?.message || err.message;
        if (msg.includes("is not enabled") || msg.includes("not found")) {
          console.log(`  ${api} not enabled on ${projectId}, skipping.`);
        } else {
          console.error(`  Failed to disable ${api} on ${projectId}: ${msg}`);
        }
      }
    }
  }
  // In "billing" mode, disableBilling is called by the caller
}

async function enforceOnAccounts(accountsToDisable) {
  for (const accountId of accountsToDisable) {
    const billingAccount = `billingAccounts/${accountId}`;
    console.log(`Processing billing account ${accountId}...`);

    let projects;
    try {
      projects = await listProjects(billingAccount);
    } catch (err) {
      console.error(
        `Failed to list projects for ${accountId}:`,
        err.response?.data?.error?.message || err.message
      );
      continue;
    }

    for (const project of projects) {
      if (project.projectId === GUARD_PROJECT_ID) {
        console.log(`${project.projectId} — skipping (guard project).`);
        continue;
      }

      if (ENFORCEMENT_MODE === "billing") {
        if (!project.billingEnabled) {
          console.log(`${project.projectId} — billing already disabled.`);
          continue;
        }

        console.log(`DISABLING BILLING on ${project.projectId}...`);
        try {
          await disableBilling(project.name);
          console.log(`DONE: ${project.projectId} billing disabled.`);
        } catch (err) {
          console.error(
            `FAILED ${project.projectId}:`,
            err.response?.data?.error?.message || err.message
          );
        }
      } else {
        await enforceOnProject(project.projectId);
      }
    }
  }
}

// ── Main handler ──

exports.stopBilling = async (cloudEvent) => {
  const base64Data = extractBase64Data(cloudEvent);
  if (!base64Data) {
    console.error(
      "Could not extract data from CloudEvent:",
      JSON.stringify(cloudEvent).slice(0, 1000)
    );
    return;
  }

  let data;
  try {
    data = JSON.parse(Buffer.from(base64Data, "base64").toString());
  } catch (err) {
    console.error("Failed to decode base64 data:", err.message);
    return;
  }

  console.log("Budget notification:", JSON.stringify(data));

  const costAmount = data.costAmount;
  const budgetAmount = data.budgetAmount;

  if (costAmount == null || budgetAmount == null) {
    console.error("Missing costAmount or budgetAmount.");
    return;
  }

  const ratio = costAmount / budgetAmount;
  console.log(
    `Cost: $${costAmount}, Budget: $${budgetAmount}, Ratio: ${(ratio * 100).toFixed(1)}%, Mode: ${ENFORCEMENT_MODE}`
  );

  // Determine which billing account(s) to act on
  const attributes =
    cloudEvent.data?.message?.attributes || cloudEvent.data?.attributes || {};
  const billingAccountId =
    attributes.billingAccountId || data.billingAccountId;
  const accountsToDisable = billingAccountId
    ? [billingAccountId]
    : MANAGED_BILLING_ACCOUNTS;

  if (accountsToDisable.length === 0) {
    console.error(
      "No billing account to act on. Set MANAGED_BILLING_ACCOUNTS env var."
    );
    return;
  }

  // Use budget display name as stable ID for velocity tracking
  const budgetId = (data.budgetDisplayName || "unknown").replace(/[/\\]/g, "_");

  // Check for spend avalanche (velocity-based early kill)
  const isAvalanche = await detectVelocityAnomaly(budgetId, ratio);

  if (isAvalanche) {
    console.log(
      `EARLY KILL: Spend avalanche detected. Enforcing immediately at ${(ratio * 100).toFixed(1)}%.`
    );
    await enforceOnAccounts(accountsToDisable);
    console.log("Avalanche enforcement complete.");
    return;
  }

  // Standard threshold check
  if (ratio < BUDGET_THRESHOLD) {
    console.log(
      `${(ratio * 100).toFixed(1)}% < ${BUDGET_THRESHOLD * 100}% threshold. No action.`
    );
    return;
  }

  console.log(
    `BUDGET EXCEEDED at ${(ratio * 100).toFixed(1)}%. Enforcing on: ${accountsToDisable.join(", ")}`
  );

  await enforceOnAccounts(accountsToDisable);
  console.log("All accounts processed.");
};
