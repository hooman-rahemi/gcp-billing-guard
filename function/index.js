const { GoogleAuth } = require("google-auth-library");

const BUDGET_THRESHOLD = parseFloat(process.env.BUDGET_THRESHOLD || "1.0");
const BILLING_API = "https://cloudbilling.googleapis.com/v1";
const GUARD_PROJECT_ID = process.env.GOOGLE_CLOUD_PROJECT;

// Comma-separated list of billing account IDs this guard manages.
// Set via environment variable during deployment.
const MANAGED_BILLING_ACCOUNTS = (process.env.MANAGED_BILLING_ACCOUNTS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const auth = new GoogleAuth({
  scopes: ["https://www.googleapis.com/auth/cloud-billing"],
});

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

/**
 * Extract base64-encoded data from the CloudEvent.
 * Eventarc wraps Pub/Sub messages differently depending on configuration:
 *   - cloudEvent.data.message.data  (standard CloudEvent Pub/Sub binding)
 *   - cloudEvent.data               (direct base64 string via Eventarc)
 */
function extractBase64Data(cloudEvent) {
  const d = cloudEvent.data;
  if (!d) return null;
  if (d.message && d.message.data) return d.message.data;
  if (typeof d.data === "string") return d.data;
  if (typeof d === "string") return d;
  return null;
}

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
    `Cost: $${costAmount}, Budget: $${budgetAmount}, Ratio: ${(ratio * 100).toFixed(1)}%`
  );

  if (ratio < BUDGET_THRESHOLD) {
    console.log(
      `${(ratio * 100).toFixed(1)}% < ${BUDGET_THRESHOLD * 100}% threshold. No action.`
    );
    return;
  }

  // Determine which billing account triggered this alert.
  const attributes =
    cloudEvent.data?.message?.attributes || cloudEvent.data?.attributes || {};
  const billingAccountId =
    attributes.billingAccountId || data.billingAccountId;

  // If we can identify the specific account, disable just that one.
  // Otherwise, disable all managed accounts.
  const accountsToDisable = billingAccountId
    ? [billingAccountId]
    : MANAGED_BILLING_ACCOUNTS;

  if (accountsToDisable.length === 0) {
    console.error(
      "No billing account to disable. Set MANAGED_BILLING_ACCOUNTS env var."
    );
    return;
  }

  console.log(
    `BUDGET EXCEEDED at ${(ratio * 100).toFixed(1)}%. Disabling billing on: ${accountsToDisable.join(", ")}`
  );

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
      // Never disable billing on the guard project itself
      if (project.projectId === GUARD_PROJECT_ID) {
        console.log(`${project.projectId} — skipping (guard project).`);
        continue;
      }

      if (!project.billingEnabled) {
        console.log(`${project.projectId} — already disabled.`);
        continue;
      }

      console.log(`Disabling billing on ${project.projectId}...`);
      try {
        await disableBilling(project.name);
        console.log(`DONE: ${project.projectId} billing disabled.`);
      } catch (err) {
        console.error(
          `FAILED ${project.projectId}:`,
          err.response?.data?.error?.message || err.message
        );
      }
    }
  }

  console.log("All accounts processed.");
};
