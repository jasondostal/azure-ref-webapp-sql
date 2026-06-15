using '../main.bicep'

// ── QA ───────────────────────────────────────────────────────────────────────
// Secrets come from vg-refapp-qa via the pipeline (see dev.bicepparam header).

param environment = 'qa'
param location = 'eastus'
param appName = 'refapp'
param vnetAddressPrefix = '10.20.0.0/16'

// SQL admin Entra group — the deploy SP must be a member (see README).
param sqlAdminGroupName = 'sg-refapp-qa-sqladmins'  // adjust to your group
param sqlAdminGroupObjectId = ''     // REQUIRED — the group's objectId

// Secrets — empty here; the pipeline overrides them at deploy with a second
// --parameters from vg-refapp-qa (Key Vault). Never commit real values.
param tenantId = ''
param sqlAdminLogin = ''
param sqlAdminPassword = ''

param aspSkuName = 'B1'
param aspSkuTier = 'Basic'
param sqlSkuName = 'Basic'
param sqlSkuTier = 'Basic'

param deploySelfHostedAgent = true
param azpUrl = ''            // REQUIRED
param azpPool = 'refapp-qa'
param acrResourceId = ''     // REQUIRED
param acrLoginServer = ''    // REQUIRED
param agentImage = ''        // REQUIRED
