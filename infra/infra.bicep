targetScope = 'subscription'

// ═══════════════════════════════════════════════════════════════════════════
// azure-ref-webapp-sql — infra.bicep  (THE INFRA LAYER)
//
// Deployed by the PLATFORM/INFRA team, with subscription-level rights, on the
// infra service connection. It provisions the things an app team should NOT own:
//
//   • the env's resource group            (a subscription-level write)
//   • the VNet + subnets + private DNS     (cross-cutting networking)
//   • the self-hosted ADO agent + its AcrPull grant on the SHARED ACR
//     (a cross-RG role assignment the RG-scoped dev identity can't make)
//
// The app team then deploys app.bicep INTO this RG, scoped to it, via their
// RG-scoped service connection. See app.bicep for the other half.
//
// Run once per environment (dev/qa/stage/prod), same subscription:
//   az deployment sub create --location eastus \
//     --template-file infra/infra.bicep \
//     --parameters infra/params/<env>.infra.bicepparam \
//     --parameters azpToken=$(azpToken)
// ═══════════════════════════════════════════════════════════════════════════

@description('Environment name: dev, qa, stage, prod')
@allowed(['dev', 'qa', 'stage', 'prod'])
param environment string

@description('Azure region')
param location string = 'eastus'

@description('Base name for all resources')
param appName string = 'refapp'

@description('Per-env VNet address space (non-overlapping so VNets can be peered later).')
param vnetAddressPrefix string = '10.0.0.0/16'

// ── Self-hosted ADO agent (the deploy mechanism — infra owns it) ────────────

@description('Deploy the self-hosted ADO agent into this environment VNet.')
param deploySelfHostedAgent bool = true

@description('Azure DevOps organization URL, e.g. https://dev.azure.com/your-org')
param azpUrl string = ''

@description('ADO agent pool the agent registers into (e.g. refapp-dev).')
param azpPool string = ''

@description('PAT with Agent Pools (Read & Manage). From Key Vault — agent registration has no WIF path.')
@secure()
param azpToken string = ''

@description('Resource ID of the SHARED ACR hosting the ado-agent image (platform bootstrap).')
param acrResourceId string = ''

@description('Shared ACR login server, e.g. refacr.azurecr.io')
param acrLoginServer string = ''

@description('Agent container image tag, e.g. refacr.azurecr.io/ado-agent:latest')
param agentImage string = ''

// ── Resource group (infra creates it — a subscription-level write) ──────────

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${appName}-${environment}'
  location: location
  tags: {
    environment: environment
    app: appName
    managedBy: 'azure-ref-webapp-sql'
    layer: 'infra'
  }
}

// ── VNet — app-service / private-endpoints / ado-agents subnets ─────────────

module vnet '../../azure-platform-iac/modules/networking/vnet.bicep' = {
  name: '${appName}-vnet-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-vnet-${environment}'
    location: location
    addressPrefix: vnetAddressPrefix
    environment: environment
    subnets: [
      { name: 'app-service', prefix: cidrSubnet(vnetAddressPrefix, 24, 0), delegationService: 'Microsoft.Web/serverFarms' }
      { name: 'private-endpoints', prefix: cidrSubnet(vnetAddressPrefix, 24, 1) }
      { name: 'ado-agents', prefix: cidrSubnet(vnetAddressPrefix, 24, 2), delegationService: 'Microsoft.ContainerInstance/containerGroups' }
    ]
  }
}

// ── Private DNS zones — SQL + App Service, linked to this env's VNet ─────────

module dnsZones '../../azure-platform-iac/modules/networking/private-dns-zones.bicep' = {
  name: '${appName}-dns-${environment}'
  scope: resourceGroup
  params: {
    vnetId: vnet.outputs.id
    environment: environment
    zones: [
      'privatelink.database.windows.net'
      'privatelink.azurewebsites.net'
    ]
  }
}

// ── Self-hosted ADO agent — into the ado-agents subnet, with AcrPull on the
// shared ACR. The agent-aci module makes that AcrPull role assignment; it works
// here because infra.bicep is deployed with subscription-level rights.

module adoAgent '../../azure-platform-iac/modules/devops/agent-aci.bicep' = if (deploySelfHostedAgent) {
  name: '${appName}-agent-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-agent-${environment}'
    location: location
    subnetId: vnet.outputs.subnetIds[2].id
    image: agentImage
    acrId: acrResourceId
    acrLoginServer: acrLoginServer
    azpUrl: azpUrl
    azpPool: azpPool
    azpToken: azpToken
    environment: environment
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output resourceGroupName string = resourceGroup.name
output vnetName string = vnet.outputs.name
