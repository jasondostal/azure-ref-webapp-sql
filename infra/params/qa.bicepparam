using '../app.bicep'

// ── QA · APP LAYER (deployed by the app team into rg-refapp-qa) ──
// Secrets (tenantId, sqlAdminLogin, sqlAdminPassword) are overridden at deploy
// by the pipeline from vg-refapp-qa. Never commit real values.

param environment = 'qa'
param location = 'eastus'
param appName = 'refapp'

// SQL admin Entra group — the deploy SP must be a member (see README).
param sqlAdminGroupName = 'sg-refapp-qa-sqladmins'  // adjust to your group
param sqlAdminGroupObjectId = ''     // REQUIRED — the group's objectId

param aspSkuName = 'B1'
param aspSkuTier = 'Basic'
param sqlSkuName = 'Basic'
param sqlSkuTier = 'Basic'

// Secrets — empty here; overridden at deploy from vg-refapp-qa (Key Vault).
param tenantId = ''
param sqlAdminLogin = ''
param sqlAdminPassword = ''
