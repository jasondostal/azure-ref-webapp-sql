using '../infra.bicep'

// ── QA · INFRA LAYER (deployed by the platform team, sub-scoped) ──
// azpToken is overridden at deploy from the infra variable group (Key Vault).

param environment = 'qa'
param location = 'eastus'
param appName = 'refapp'
param vnetAddressPrefix = '10.20.0.0/16'

// Self-hosted agent — fill from the platform bootstrap outputs.
param deploySelfHostedAgent = true
param azpUrl = ''            // REQUIRED e.g. https://dev.azure.com/your-org
param azpPool = 'refapp-qa'
param acrResourceId = ''     // REQUIRED — shared platform ACR resource ID
param acrLoginServer = ''    // REQUIRED e.g. refacr.azurecr.io
param agentImage = ''        // REQUIRED e.g. refacr.azurecr.io/ado-agent:latest
