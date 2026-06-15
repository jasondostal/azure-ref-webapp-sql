using '../main.bicep'

// ── PROD ─────────────────────────────────────────────────────────────────────
// Secrets come from vg-refapp-prod via the pipeline (see dev.bicepparam header).

param environment = 'prod'
param location = 'eastus'
param appName = 'refapp'
param vnetAddressPrefix = '10.40.0.0/16'

// SQL admin Entra group — the deploy SP must be a member (see README).
param sqlAdminGroupName = 'sg-refapp-prod-sqladmins'  // adjust to your group
param sqlAdminGroupObjectId = ''     // REQUIRED — the group's objectId

// Secrets — empty here; the pipeline overrides them at deploy with a second
// --parameters from vg-refapp-prod (Key Vault). Never commit real values.
param tenantId = ''
param sqlAdminLogin = ''
param sqlAdminPassword = ''

param aspSkuName = 'P1v3'
param aspSkuTier = 'PremiumV3'
param sqlSkuName = 'S1'
param sqlSkuTier = 'Standard'

param deploySelfHostedAgent = true
param azpUrl = ''            // REQUIRED
param azpPool = 'refapp-prod'
param acrResourceId = ''     // REQUIRED
param acrLoginServer = ''    // REQUIRED
param agentImage = ''        // REQUIRED
