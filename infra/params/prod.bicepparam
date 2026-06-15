using '../app.bicep'

// ── PROD · APP LAYER (deployed by the app team into rg-refapp-prod) ──
// Secrets (tenantId, sqlAdminLogin, sqlAdminPassword) are overridden at deploy
// by the pipeline from vg-refapp-prod. Never commit real values.

param environment = 'prod'
param location = 'eastus'
param appName = 'refapp'

// SQL admin Entra group — the deploy SP must be a member (see README).
param sqlAdminGroupName = 'sg-refapp-prod-sqladmins'  // adjust to your group
param sqlAdminGroupObjectId = ''     // REQUIRED — the group's objectId

param aspSkuName = 'P1v3'
param aspSkuTier = 'PremiumV3'
param sqlSkuName = 'S1'
param sqlSkuTier = 'Standard'

// Secrets — empty here; overridden at deploy from vg-refapp-prod (Key Vault).
param tenantId = ''
param sqlAdminLogin = ''
param sqlAdminPassword = ''
