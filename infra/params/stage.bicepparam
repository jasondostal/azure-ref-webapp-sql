using '../main.bicep'

// ── STAGE ────────────────────────────────────────────────────────────────────
// Secrets come from vg-refapp-stage via the pipeline (see dev.bicepparam header).
// Production-like sizing so perf/load testing is representative.

param environment = 'stage'
param location = 'eastus'
param appName = 'refapp'
param vnetAddressPrefix = '10.30.0.0/16'

// SQL admin Entra group — the deploy SP must be a member (see README).
param sqlAdminGroupName = 'sg-refapp-stage-sqladmins'  // adjust to your group
param sqlAdminGroupObjectId = ''     // REQUIRED — the group's objectId

// Secrets — empty here; the pipeline overrides them at deploy with a second
// --parameters from vg-refapp-stage (Key Vault). Never commit real values.
param tenantId = ''
param sqlAdminLogin = ''
param sqlAdminPassword = ''

param aspSkuName = 'P1v3'
param aspSkuTier = 'PremiumV3'
param sqlSkuName = 'S1'
param sqlSkuTier = 'Standard'

param deploySelfHostedAgent = true
param azpUrl = ''            // REQUIRED
param azpPool = 'refapp-stage'
param acrResourceId = ''     // REQUIRED
param acrLoginServer = ''    // REQUIRED
param agentImage = ''        // REQUIRED
