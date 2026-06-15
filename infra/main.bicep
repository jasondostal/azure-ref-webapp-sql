targetScope = 'subscription'

// ═══════════════════════════════════════════════════════════════════════════
// azure-ref-webapp-sql — main.bicep
//
// CANONICAL REFERENCE ARCHITECTURE — the minimal, private-by-default
// enterprise baseline:
//
//   4 environments → 4 resource groups → 4 VNets
//   monolithic .NET web app on App Service
//   Azure SQL database (passwordless / Entra-only)
//   ALL data planes behind private endpoints (no public access)
//   self-hosted Azure DevOps agent in each VNet (the ONLY thing that can
//   deploy into the private estate)
//
// This file is the per-environment orchestrator. It deploys ONE environment;
// the infra pipeline runs it four times (dev/qa/stage/prod) against four
// subscriptions/RGs, each fed by its own params/<env>.bicepparam.
//
// It composes platform modules from the sibling repo — no infra logic is
// duplicated here. A change to a platform module propagates to this repo on
// its next deploy.
//   Platform modules: ../../azure-platform-iac/modules/
// ═══════════════════════════════════════════════════════════════════════════

// ── Core ────────────────────────────────────────────────────────────────────

@description('Environment name: dev, qa, stage, prod')
@allowed(['dev', 'qa', 'stage', 'prod'])
param environment string

@description('Azure region')
param location string = 'eastus'

@description('Base name for all resources (keep short — SQL server names are globally unique)')
param appName string = 'refapp'

@description('Tenant ID (Entra ID directory)')
param tenantId string

@description('Per-env VNet address space. Each environment gets its own non-overlapping space so the VNets can be peered later if needed.')
param vnetAddressPrefix string = '10.0.0.0/16'

// ── Sizing (per-environment, set in params/<env>.bicepparam) ────────────────

@description('App Service Plan SKU name (B1 for dev/qa, P1v3 for stage/prod). Must be Basic+ — managed identity is unavailable on Free/Shared.')
param aspSkuName string = 'B1'

@description('App Service Plan SKU tier (Basic, PremiumV3)')
param aspSkuTier string = 'Basic'

@description('SQL database SKU name (Basic for dev/qa, S1+ for stage/prod)')
param sqlSkuName string = 'Basic'

@description('SQL database SKU tier (Basic, Standard)')
param sqlSkuTier string = 'Basic'

// ── SQL admin (break-glass only — the app uses passwordless managed identity) ─

@description('SQL admin login. Only used for break-glass; entraOnlyAuth disables password auth by default.')
@secure()
param sqlAdminLogin string

@description('SQL admin password. Only used for break-glass.')
@secure()
param sqlAdminPassword string

@description('Entra-only SQL auth — when true, SQL-password auth is disabled and the app reaches SQL passwordless via its managed identity.')
param entraOnlyAuth bool = true

@description('Display name of the Entra group that administers SQL (e.g. sg-refapp-sqladmins). The pipeline deploy service principal MUST be a member — that membership is what lets the provisioning step create the app MI DB user.')
param sqlAdminGroupName string

@description('Object ID of the SQL admin Entra group.')
param sqlAdminGroupObjectId string

// ── Self-hosted Azure DevOps agent ──────────────────────────────────────────
// In a private-endpoint estate the App Service SCM endpoint and SQL are
// reachable ONLY from inside the VNet. Microsoft-hosted agents live outside the
// tenant and cannot route to them — so deploys MUST run on a VNet-injected
// self-hosted agent. This deploys one per environment, into that env's VNet.

@description('Deploy the self-hosted ADO agent into this environment VNet. Leave true for the private-by-default posture.')
param deploySelfHostedAgent bool = true

@description('Azure DevOps organization URL, e.g. https://dev.azure.com/your-org')
param azpUrl string = ''

@description('ADO agent pool the agent registers into (e.g. refapp-dev). Each env registers into its own pool.')
param azpPool string = ''

@description('PAT with Agent Pools (Read & Manage). Source from Key Vault via the infra variable group — agent registration has no Workload Identity Federation path.')
@secure()
param azpToken string = ''

@description('Resource ID of the ACR hosting the ado-agent image (created by the platform bootstrap).')
param acrResourceId string = ''

@description('ACR login server, e.g. refacr.azurecr.io')
param acrLoginServer string = ''

@description('Agent container image tag, e.g. refacr.azurecr.io/ado-agent:latest')
param agentImage string = ''

// ═══════════════════════════════════════════════════════════════════════════
// Resource Group — one per environment
// ═══════════════════════════════════════════════════════════════════════════

var resourceGroupName = 'rg-${appName}-${environment}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    environment: environment
    app: appName
    managedBy: 'azure-ref-webapp-sql'
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Networking — one VNet per environment
//   app-service        → delegated to Microsoft.Web/serverFarms (VNet integ.)
//   private-endpoints  → holds the SQL + App Service private endpoints
//   ado-agents         → delegated to ACI; the self-hosted agent lives here
// ═══════════════════════════════════════════════════════════════════════════

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

var appSubnetId = vnet.outputs.subnetIds[0].id
var peSubnetId = vnet.outputs.subnetIds[1].id
var agentSubnetId = vnet.outputs.subnetIds[2].id

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

var sqlDnsZoneId = dnsZones.outputs.zoneIds[0].id
var appDnsZoneId = dnsZones.outputs.zoneIds[1].id

// ═══════════════════════════════════════════════════════════════════════════
// Compute — App Service Plan + monolithic .NET web app
// ═══════════════════════════════════════════════════════════════════════════

module appServicePlan '../../azure-platform-iac/modules/compute/app-service-plan.bicep' = {
  name: '${appName}-asp-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-asp-${environment}'
    location: location
    skuName: aspSkuName
    skuTier: aspSkuTier
    osKind: 'linux'
    environment: environment
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Data — Azure SQL server + database (passwordless, private)
// ═══════════════════════════════════════════════════════════════════════════

module sqlServer '../../azure-platform-iac/modules/data/sql-server.bicep' = {
  name: '${appName}-sql-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-sql-${environment}'
    location: location
    adminLogin: sqlAdminLogin
    adminPassword: sqlAdminPassword
    disablePublicAccess: true
    allowAzureServices: false
    tenantId: tenantId
    entraAdminLogin: sqlAdminGroupName
    entraAdminSid: sqlAdminGroupObjectId
    entraAdminPrincipalType: 'Group'
    entraOnlyAuth: entraOnlyAuth
    environment: environment
  }
}

module sqlDatabase '../../azure-platform-iac/modules/data/sql-database.bicep' = {
  name: '${appName}-sqldb-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-db-${environment}'
    location: location
    sqlServerName: sqlServer.outputs.name
    skuName: sqlSkuName
    skuTier: sqlSkuTier
    environment: environment
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// App Service — monolithic .NET web app, VNet-integrated, passwordless to SQL.
// Public access stays ON (the app is the front door); SQL + the SCM/deploy
// plane are what go private. Outbound to SQL flows through the VNet.
// ═══════════════════════════════════════════════════════════════════════════

// Passwordless connection string — the app's system-assigned MI authenticates
// to SQL. No User ID / Password — nothing secret in app config.
var sqlConnStr = 'Server=tcp:${sqlServer.outputs.fqdn},1433;Initial Catalog=${sqlDatabase.outputs.name};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'

module appService '../../azure-platform-iac/modules/compute/app-service.bicep' = {
  name: '${appName}-app-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-app-${environment}'
    location: location
    appServicePlanId: appServicePlan.outputs.id
    runtimeStack: 'DOTNETCORE|10.0'
    alwaysOn: (environment == 'stage' || environment == 'prod')
    environment: environment
    enableVnetIntegration: true
    vnetSubnetId: appSubnetId
    enableManagedIdentity: true
    connectionStrings: {
      DefaultConnection: sqlConnStr
    }
    appSettings: {
      ASPNETCORE_ENVIRONMENT: (environment == 'prod' ? 'Production' : 'Staging')
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Private endpoints — SQL server + App Service, in the private-endpoints subnet
// ═══════════════════════════════════════════════════════════════════════════

module sqlPrivateEndpoint '../../azure-platform-iac/modules/networking/private-endpoint.bicep' = {
  name: '${appName}-pe-sql-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-pe-sql-${environment}'
    location: location
    subnetId: peSubnetId
    targetResourceId: sqlServer.outputs.id
    groupId: 'sqlServer'
    privateDnsZoneId: sqlDnsZoneId
    environment: environment
  }
}

module appPrivateEndpoint '../../azure-platform-iac/modules/networking/private-endpoint.bicep' = {
  name: '${appName}-pe-app-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-pe-app-${environment}'
    location: location
    subnetId: peSubnetId
    targetResourceId: appService.outputs.id
    groupId: 'sites'
    privateDnsZoneId: appDnsZoneId
    environment: environment
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Self-hosted ADO agent — VNet-injected into the ado-agents subnet.
// REQUIRED to deploy the app (private SCM endpoint) and to run SQL provisioning
// (private SQL). Microsoft-hosted agents physically cannot reach either.
// ═══════════════════════════════════════════════════════════════════════════

module adoAgent '../../azure-platform-iac/modules/devops/agent-aci.bicep' = if (deploySelfHostedAgent) {
  name: '${appName}-agent-${environment}'
  scope: resourceGroup
  params: {
    name: '${appName}-agent-${environment}'
    location: location
    subnetId: agentSubnetId
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
output appServiceName string = appService.outputs.name
output appServiceHostName string = appService.outputs.defaultHostName
output appServicePrincipalId string = appService.outputs.managedIdentityPrincipalId
output sqlServerName string = sqlServer.outputs.name
output sqlServerFqdn string = sqlServer.outputs.fqdn
output sqlDatabaseName string = sqlDatabase.outputs.name
