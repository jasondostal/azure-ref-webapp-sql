targetScope = 'resourceGroup'

// ═══════════════════════════════════════════════════════════════════════════
// azure-ref-webapp-sql — app.bicep  (THE APP LAYER)
//
// Deployed by the APP TEAM, scoped to ONE resource group, via their RG-scoped
// service connection (rbac-scope=rg). It owns the application resources:
//
//   • App Service plan + the monolithic .NET web app (VNet-integrated)
//   • Azure SQL server + database (passwordless / Entra-only)
//   • private endpoints for SQL + App Service
//
// It does NOT create the RG, the VNet, or the agent — infra.bicep already did
// (see that file). It references the existing VNet + private DNS zones BY NAME,
// in this same resource group. Because everything here lives inside the RG, an
// RG-scoped Contributor identity can deploy it — and physically cannot touch
// any other environment.
//
//   az deployment group create -g rg-<appName>-<env> \
//     --template-file infra/app.bicep \
//     --parameters infra/params/<env>.bicepparam \
//     --parameters sqlAdminLogin=$(x) sqlAdminPassword=$(y) tenantId=$(z)
// ═══════════════════════════════════════════════════════════════════════════

// ── Core ────────────────────────────────────────────────────────────────────

@description('Environment name: dev, qa, stage, prod')
@allowed(['dev', 'qa', 'stage', 'prod'])
param environment string

@description('Azure region')
param location string = 'eastus'

@description('Region for Azure SQL. Defaults to the app region (co-located). Override when the home region is capacity-constrained for SQL — the private endpoint stays in the app VNet (this region) and targets the SQL cross-region.')
param sqlLocation string = location

@description('Base name for all resources (keep short — SQL server names are globally unique)')
param appName string = 'refapp'

@description('SQL logical server name. Globally unique — override if the default name is taken/reserved. The app reaches it by FQDN, so the name is free to change.')
param sqlServerName string = '${appName}-sql-${environment}'

@description('Tenant ID (Entra ID directory)')
param tenantId string

// ── Sizing ──────────────────────────────────────────────────────────────────

@description('App Service Plan SKU name (B1 for dev/qa, P1v3 for stage/prod). Basic+ required — managed identity is unavailable on Free/Shared.')
param aspSkuName string = 'B1'

@description('App Service Plan SKU tier (Basic, PremiumV3)')
param aspSkuTier string = 'Basic'

@description('SQL database SKU name (Basic for dev/qa, S1+ for stage/prod)')
param sqlSkuName string = 'Basic'

@description('SQL database SKU tier (Basic, Standard)')
param sqlSkuTier string = 'Basic'

// ── SQL admin (break-glass only — the app uses passwordless managed identity) ─

@description('SQL admin login. Break-glass only; entraOnlyAuth disables password auth by default.')
@secure()
param sqlAdminLogin string

@description('SQL admin password. Break-glass only.')
@secure()
param sqlAdminPassword string

@description('Entra-only SQL auth — when true, password auth is off and the app reaches SQL passwordless via its managed identity.')
param entraOnlyAuth bool = true

@description('Display name of the Entra group that administers SQL. The deploy SP must be a member — that membership lets the provisioning step create the app MI DB user.')
param sqlAdminGroupName string

@description('Object ID of the SQL admin Entra group.')
param sqlAdminGroupObjectId string

// ═══════════════════════════════════════════════════════════════════════════
// Existing infra (provisioned by infra.bicep) — referenced by name, same RG
// ═══════════════════════════════════════════════════════════════════════════

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: '${appName}-vnet-${environment}'
}

var appSubnetId = '${vnet.id}/subnets/app-service'
var peSubnetId = '${vnet.id}/subnets/private-endpoints'

resource sqlDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.database.windows.net'
}

resource appDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.azurewebsites.net'
}

// ═══════════════════════════════════════════════════════════════════════════
// Compute — App Service Plan + monolithic .NET web app
// ═══════════════════════════════════════════════════════════════════════════

module appServicePlan '../../azure-platform-iac/modules/compute/app-service-plan.bicep' = {
  name: '${appName}-asp-${environment}'
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
  params: {
    name: sqlServerName
    location: sqlLocation
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
  params: {
    name: '${appName}-db-${environment}'
    location: sqlLocation
    sqlServerName: sqlServer.outputs.name
    skuName: sqlSkuName
    skuTier: sqlSkuTier
    environment: environment
  }
}

// Passwordless connection string — the app's system-assigned MI authenticates
// to SQL. No User ID / Password — nothing secret in app config.
// NOTE: Initial Catalog must be the bare database name. sqlDatabase.outputs.name
// is the ARM resource name '<server>/<database>' — using it directly points the
// app at a non-existent DB and surfaces as a confusing SQL *login* failure.
var databaseName = '${appName}-db-${environment}'
var sqlConnStr = 'Server=tcp:${sqlServer.outputs.fqdn},1433;Initial Catalog=${databaseName};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'

module appService '../../azure-platform-iac/modules/compute/app-service.bicep' = {
  name: '${appName}-app-${environment}'
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
    // ASPNETCORE_ENVIRONMENT is set by the platform module's defaults — don't
    // duplicate it here or App Service rejects the deploy (duplicate app setting).
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Private endpoints — SQL server + App Service, in the private-endpoints subnet
// ═══════════════════════════════════════════════════════════════════════════

module sqlPrivateEndpoint '../../azure-platform-iac/modules/networking/private-endpoint.bicep' = {
  name: '${appName}-pe-sql-${environment}'
  params: {
    name: '${appName}-pe-sql-${environment}'
    location: location
    subnetId: peSubnetId
    targetResourceId: sqlServer.outputs.id
    groupId: 'sqlServer'
    privateDnsZoneId: sqlDnsZone.id
    environment: environment
  }
}

module appPrivateEndpoint '../../azure-platform-iac/modules/networking/private-endpoint.bicep' = {
  name: '${appName}-pe-app-${environment}'
  params: {
    name: '${appName}-pe-app-${environment}'
    location: location
    subnetId: peSubnetId
    targetResourceId: appService.outputs.id
    groupId: 'sites'
    privateDnsZoneId: appDnsZone.id
    environment: environment
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output appServiceName string = appService.outputs.name
output appServiceHostName string = appService.outputs.defaultHostName
output appServicePrincipalId string = appService.outputs.managedIdentityPrincipalId
output sqlServerName string = sqlServer.outputs.name
output sqlServerFqdn string = sqlServer.outputs.fqdn
output sqlDatabaseName string = sqlDatabase.outputs.name
