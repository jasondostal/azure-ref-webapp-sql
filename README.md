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
| [azure-iac-patterns](../azure-iac-patterns) | Standalone module library |
| [azure-project-starter](../azure-project-starter) | Cookiecutter — generate a new wired-up service repo |
| **azure-ref-webapp-sql** (this repo) | Minimal private-by-default reference: web app + SQL + 4 envs |
| [azure-playground](../azure-playground) | The cheap, always-on sandbox — the inverse of this repo (public, 1 RG, scale-to-zero) |

## Two layers — separation of duties

This reference is deployed in **two layers**, by **two identities**, demonstrating least-privilege in a single subscription (the Fox model: one sub, one RG per env):

| Layer | File | Who / scope | Deploys |
|-------|------|-------------|---------|
| **Infra** | `infra/infra.bicep` (subscription scope) | platform team · `$(infraServiceConnection)` (sub-scoped) | the RG, VNet + subnets + private DNS, and the self-hosted ADO agent (+ its cross-RG AcrPull on the shared ACR) |
| **App** | `infra/app.bicep` (resource-group scope) | app team · `$(<env>ServiceConnection)` (RG-scoped, from `onboard-subscription.sh --rbac-scope rg`) | App Service plan + App Service, Azure SQL + database, private endpoints — **into the existing RG/VNet** |

Why split: an RG-scoped deploy identity (Contributor on `rg-refapp-<env>` only) **cannot** create its own RG, configure cross-cutting networking, or grant AcrPull on the shared ACR — those are subscription-level / cross-RG writes. So infra provisions the room, the network, and the deploy agent; the app team only deploys app resources, and physically cannot reach another environment.

### What each layer deploys (per environment)

| Resource | Layer · Module | Notes |
|----------|----------------|-------|
| Resource group `rg-refapp-<env>` | infra (inline) | one per environment |
| VNet `refapp-vnet-<env>` | infra · `networking/vnet` | non-overlapping space (10.10/20/30/40.0.0/16); subnets: `app-service` (delegated), `private-endpoints`, `ado-agents` (delegated to ACI) |
| Private DNS zones | infra · `networking/private-dns-zones` | `database.windows.net`, `azurewebsites.net`, linked to the VNet |
| Self-hosted ADO agent | infra · `devops/agent-aci` | VNet-injected ACI in `ado-agents`; AcrPull on the shared ACR |
| App Service Plan | app · `compute/app-service-plan` | B1 (dev/qa) / P1v3 (stage/prod) — Basic+ required for managed identity |
| App Service | app · `compute/app-service` | .NET 10, VNet-integrated, system-assigned MI |
| Azure SQL server + database | app · `data/sql-server`, `data/sql-database` | public access disabled; Entra-only auth; admin = Entra group |
| Private endpoints (SQL + App Service) | app · `networking/private-endpoint` | in the `private-endpoints` subnet |

## Why a self-hosted agent is mandatory here

With SQL public access disabled and a private endpoint on the App Service, those resources are reachable **only from inside the VNet**. Microsoft-hosted ADO agents live on Microsoft's network, outside your tenant — they cannot route to a private endpoint. A deploy that pushes app bits to the private SCM endpoint, or runs SQL provisioning against private SQL, must run on a **VNet-injected self-hosted agent**. That is why infra deploys one agent per environment and the relevant stages run on the `refapp-<env>` self-hosted pool.

Bootstrap ordering: the *ARM control plane* (creating the agent ACI, VNet, etc.) is reachable from a hosted agent, so the infra layer runs hosted. Once the agent is registered, the data-plane steps (app code push, SQL provisioning) run on it.

## Pipelines

Both consume shared templates from `azure-platform-iac` via a pipeline `resources.repositories` reference.

- **`pipelines/azure-pipelines.yml`** — app CI/CD. Build → Scan on hosted agents; **deploy stages on the self-hosted pool** (`pool: { name: 'refapp-<env>' }`). Build once, promote the same artifact dev→qa→stage→prod, gated by ADO Environment approvals.
- **`pipelines/infra-pipeline.yml`** — Bicep, two layers per env: **infra** (`infra.bicep` on `$(infraServiceConnection)`, sub-scoped) → **app** (`app.bicep` on the RG-scoped `$(<env>ServiceConnection)`) → **SQL provision** on the self-hosted pool. Promoted dev→qa→stage→prod, approval-gated.

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
| `infraServiceConnection` | `vg-refapp-shared` | a **subscription-scoped** service connection the platform team owns (deploys the infra layer). Distinct from the RG-scoped per-env ones |
| `<env>ServiceConnection` | `vg-refapp-<env>` | the **RG-scoped** connection from `onboard-subscription.sh --rbac-scope rg` (deploys the app layer) |
| `tenantId`, `sqlAdminLogin`, `sqlAdminPassword`, `azpToken` | `vg-refapp-<env>` (Key Vault) → pipeline | secrets; overridden at deploy, never committed |
| `sqlAdminGroupObjectId` | `params/<env>.bicepparam` | objectId of the SQL admin Entra group. **The app-layer deploy SP must be a member** — that membership is what lets provisioning create the app DB user |
| `azpUrl`, `acrResourceId`, `acrLoginServer`, `agentImage`, `azpToken` | `params/<env>.bicepparam` + `vg` | from the platform bootstrap (the ACR + ado-agent image) and your ADO org/PAT |

Build the agent image first (from the platform repo):

```bash
az acr build -r <acr> -t ado-agent:latest azure-platform-iac/modules/devops/agent-image
```

## Local checks

```bash
# Bicep compiles (both layers)
az bicep build --file infra/infra.bicep
az bicep build --file infra/app.bicep
az bicep build-params --file infra/params/dev.bicepparam        # app layer
az bicep build-params --file infra/params/dev.infra.bicepparam  # infra layer

# App builds (requires .NET 10 SDK)
dotnet build ReferenceWebApp.slnx
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full data-flow walkthrough.
