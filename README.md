# azure-ref-webapp-sql

Canonical reference architecture: a monolithic .NET web app on Azure, private by default, promoted across four environments. The minimal enterprise baseline — no APIM, no Foundry, no B2C. Just the load-bearing pattern.

```
4 environments  →  4 resource groups  →  4 VNets
        │
        ├── monolithic .NET web app on App Service (VNet-integrated)
        ├── Azure SQL database (passwordless, Entra-only)
        ├── private endpoints on SQL + App Service (no public data plane)
        └── self-hosted Azure DevOps agent in each VNet
```

It composes Bicep modules from [azure-platform-iac](../azure-platform-iac) — no infrastructure logic is duplicated here. A change to a platform module reaches this app on its next deploy.

## Related repos

| Repo | Purpose |
|------|---------|
| [azure-platform-iac](../azure-platform-iac) | Platform modules (this repo's dependencies) + shared pipeline templates |
| **azure-ref-webapp-sql** (this repo) | Minimal private-by-default reference: web app + SQL + 4 envs |
| [azure-iac-reference](../azure-iac-reference) | Maximalist showcase (adds APIM, B2C, Foundry, AI Search) |
| [azure-project-starter](../azure-project-starter) | Cookiecutter — generate a new project repo |

## What gets deployed (per environment)

`infra/main.bicep` is the per-environment orchestrator (subscription scope). The infra pipeline runs it four times — `dev`, `qa`, `stage`, `prod` — each against its own subscription/RG, fed by `infra/params/<env>.bicepparam`.

| Resource | Module | Notes |
|----------|--------|-------|
| Resource group `rg-refapp-<env>` | (inline) | one per environment |
| VNet `refapp-vnet-<env>` | `networking/vnet` | per-env, non-overlapping space (10.10/20/30/40.0.0/16); subnets: `app-service` (delegated), `private-endpoints`, `ado-agents` (delegated to ACI) |
| Private DNS zones | `networking/private-dns-zones` | `database.windows.net`, `azurewebsites.net`, linked to the VNet |
| App Service Plan | `compute/app-service-plan` | B1 (dev/qa) / P1v3 (stage/prod) — Basic+ required for managed identity |
| App Service | `compute/app-service` | .NET 10, VNet-integrated, system-assigned MI |
| Azure SQL server + database | `data/sql-server`, `data/sql-database` | public access disabled; Entra-only auth; admin = Entra group |
| Private endpoints (SQL + App Service) | `networking/private-endpoint` | in the `private-endpoints` subnet |
| Self-hosted ADO agent | `devops/agent-aci` | VNet-injected ACI in the `ado-agents` subnet |

## Why a self-hosted agent is mandatory here

With SQL public access disabled and a private endpoint on the App Service, those resources are reachable **only from inside the VNet**. Microsoft-hosted ADO agents live on Microsoft's network, outside your tenant — they cannot route to a private endpoint. A deploy that pushes app bits to the private SCM endpoint, or runs SQL provisioning against private SQL, must run on a **VNet-injected self-hosted agent**. That is why this reference deploys one agent per environment and why the deploy stages override the pool.

Bootstrap ordering note: the *ARM control plane* (creating the agent ACI, VNet, etc.) is reachable from a hosted agent, so the very first `az deployment sub create` for a brand-new environment can run hosted. Once the agent is registered, the data-plane steps (app push, SQL provisioning) run on it.

## Pipelines

Both consume shared templates from `azure-platform-iac` via a pipeline `resources.repositories` reference.

- **`pipelines/azure-pipelines.yml`** — app CI/CD. Build → Scan on hosted agents; **deploy stages on the self-hosted pool** (`pool: { name: 'refapp-<env>' }`). Build once, promote the same artifact dev→qa→stage→prod, gated by ADO Environment approvals.
- **`pipelines/infra-pipeline.yml`** — Bicep. What-if (all envs) → per-env apply. The ARM apply runs hosted; the SQL-user provisioning runs on the self-hosted pool (`scripts/provision-sql-user.sh`).

## The .NET app

`src/ReferenceWebApp.Web` — a Razor Pages monolith. The index page and `/readyz` connect to SQL using `Authentication=Active Directory Managed Identity` (no secret in config). Connection string is injected by App Service as `ConnectionStrings__DefaultConnection` from Bicep.

- `/` — shows SQL connectivity status + `@@SERVERNAME`
- `/healthz` — liveness (no SQL)
- `/readyz` — readiness (executes `SELECT 1` against SQL)

## Passwordless SQL — the one wiring step that isn't pure IaC

Bicep makes the app's managed identity exist and sets the SQL Entra admin to a group. It cannot create the *database user* — that's a data-plane operation. `scripts/provision-sql-user.sh` does it (run by the self-hosted agent against private SQL):

```sql
CREATE USER [refapp-app-<env>] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '<app-mi-object-id>';
ALTER ROLE db_datareader ADD MEMBER [refapp-app-<env>];
ALTER ROLE db_datawriter ADD MEMBER [refapp-app-<env>];
```

`WITH OBJECT_ID` avoids needing the SQL server to hold the Directory Readers role.

## Before you can deploy — required inputs

These are blank in the param files on purpose (placeholders, not real values):

| Input | Where | What |
|-------|-------|------|
| `tenantId`, `sqlAdminLogin`, `sqlAdminPassword` | `vg-refapp-<env>` (Key Vault) → pipeline | secrets; overridden at deploy, never committed |
| `sqlAdminGroupObjectId` | `params/<env>.bicepparam` | objectId of the SQL admin Entra group. **The deploy service principal must be a member** — that membership is what lets provisioning create the app DB user |
| `azpUrl`, `acrResourceId`, `acrLoginServer`, `agentImage`, `azpToken` | `params/<env>.bicepparam` + `vg` | from the platform bootstrap (the ACR + ado-agent image) and your ADO org/PAT |

Build the agent image first (from the platform repo):

```bash
az acr build -r <acr> -t ado-agent:latest azure-platform-iac/modules/devops/agent-image
```

## Local checks

```bash
# Bicep compiles
az bicep build --file infra/main.bicep
az bicep build-params --file infra/params/dev.bicepparam

# App builds (requires .NET 10 SDK)
dotnet build ReferenceWebApp.slnx
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full data-flow walkthrough.
