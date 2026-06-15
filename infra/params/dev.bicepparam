using '../app.bicep'

// ── DEV · APP LAYER (deployed by the app team into rg-refapp-dev) ──
// Secrets (tenantId, sqlAdminLogin, sqlAdminPassword) are overridden at deploy
// by the pipeline from vg-refapp-dev. Never commit real values.

param environment = 'dev'
param location = 'eastus'
param appName = 'refapp'

// SQL admin Entra group — the deploy SP must be a member (see README).
param sqlAdminGroupName = 'sg-refapp-dev-sqladmins'  // adjust to your group
param sqlAdminGroupObjectId = ''     // REQUIRED — the group's objectId

param aspSkuName = 'B1'
param aspSkuTier = 'Basic'
param sqlSkuName = 'Basic'
param sqlSkuTier = 'Basic'

// Secrets — empty here; overridden at deploy from vg-refapp-dev (Key Vault).
param tenantId = ''
param sqlAdminLogin = ''
param sqlAdminPassword = ''
