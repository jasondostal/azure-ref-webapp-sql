using '../main.bicep'

// ── DEV ──────────────────────────────────────────────────────────────────────
// Secrets (tenantId, sqlAdminLogin, sqlAdminPassword, azpToken) are NOT here —
// the pipeline supplies them with a second `--parameters k=$(var)` from the
// vg-refapp-dev variable group (Key Vault backed). For a local deploy, pass them
// the same way on the az CLI.

param environment = 'dev'
param location = 'eastus'
param appName = 'refapp'
param vnetAddressPrefix = '10.10.0.0/16'

// SQL admin Entra group — the deploy SP must be a member (see README).
param sqlAdminGroupName = 'sg-refapp-dev-sqladmins'  // adjust to your group
param sqlAdminGroupObjectId = ''     // REQUIRED — the group's objectId

// Secrets — empty here; the pipeline overrides them at deploy with a second
// --parameters from vg-refapp-dev (Key Vault). Never commit real values.
param tenantId = ''
param sqlAdminLogin = ''
param sqlAdminPassword = ''

// Sizing — cheapest that still supports managed identity (Basic+).
param aspSkuName = 'B1'
param aspSkuTier = 'Basic'
param sqlSkuName = 'Basic'
param sqlSkuTier = 'Basic'

// Self-hosted agent — fill from the platform bootstrap outputs.
param deploySelfHostedAgent = true
param azpUrl = ''            // REQUIRED e.g. https://dev.azure.com/your-org
param azpPool = 'refapp-dev'
param acrResourceId = ''     // REQUIRED — platform ACR resource ID
param acrLoginServer = ''    // REQUIRED e.g. refacr.azurecr.io
param agentImage = ''        // REQUIRED e.g. refacr.azurecr.io/ado-agent:latest
