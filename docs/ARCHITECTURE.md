# Architecture

## Topology (one of four identical environments)

```
 subscription: refapp-<env>
 └── resource group: rg-refapp-<env>
     └── VNet refapp-vnet-<env>  (10.{10,20,30,40}.0.0/16)
         ├── subnet app-service        (delegated Microsoft.Web/serverFarms)
         │     └── App Service (.NET 10) — outbound via VNet integration
         ├── subnet private-endpoints
         │     ├── PE → Azure SQL server   (privatelink.database.windows.net)
         │     └── PE → App Service (sites) (privatelink.azurewebsites.net)
         └── subnet ado-agents          (delegated ACI)
               └── self-hosted ADO agent (container) — pulls image from platform ACR

     Azure SQL server (public access OFF, Entra-only, admin = Entra group)
       └── database refapp-db-<env>
```

The four environments are byte-for-byte the same shape. They differ only in:

- subscription / service connection
- VNet address space (non-overlapping, so they can be peered later)
- SKU sizing (Basic in dev/qa, PremiumV3 + Standard SQL in stage/prod)
- ADO Environment approval gates (none in dev; lead/tech-lead/VP up the chain)

## Request path: browser → app → SQL

1. A user hits the App Service public hostname (the app is the front door; only the *data plane* goes private). The App Service also has a private endpoint for internal/private-network access.
2. The app needs data. It opens a SQL connection with `Authentication=Active Directory Managed Identity`. The SqlClient driver requests an Entra token for `https://database.windows.net` using the App Service's system-assigned managed identity.
3. The outbound connection leaves the app through **VNet integration** (the `app-service` subnet), so it stays on the VNet.
4. DNS for `refapp-sql-<env>.database.windows.net` resolves — via the linked private DNS zone — to the **private endpoint** address in the `private-endpoints` subnet, not the public SQL gateway.
5. SQL validates the token against its Entra admin and the contained database user (`refapp-app-<env>`), created by `provision-sql-user.sh`. No password anywhere in the path.

## Deploy path: why two agent types

| Step | Plane | Runs on | Why |
|------|-------|---------|-----|
| `dotnet build` / test / publish | n/a | hosted | only needs source |
| security gates | n/a | hosted | only needs source |
| `az deployment sub create` (Bicep) | ARM control plane | hosted | ARM endpoints are public; this also bootstraps the agent on a fresh env |
| app zip-deploy to App Service | data plane (private SCM) | **self-hosted** | SCM endpoint is private — hosted agent can't reach it |
| `provision-sql-user.sh` | data plane (private SQL) | **self-hosted** | SQL has no public endpoint |

The self-hosted agent is therefore not a performance choice — it's the only thing on the network that can complete a deploy into a private-by-default estate.

## Identity model

- **App Service** — system-assigned MI. Its only privilege is the `db_datareader`/`db_datawriter` membership granted by the provisioning script. No Key Vault access needed (no secrets).
- **SQL admin** — an Entra **group**, not an individual or a managed identity. The pipeline's deploy service principal is a member; so are break-glass humans. Membership is the single source of "who can administer SQL," and it's what authorizes the provisioning step.
- **Agent pull identity** — a user-assigned MI with `AcrPull` on the platform ACR (created inside `devops/agent-aci`). Passwordless image pull.
- **ADO registration PAT** (`azpToken`) — the one unavoidable secret; agent registration has no Workload Identity Federation path. Sourced from Key Vault via the variable group.

## What this reference deliberately omits

To stay the *minimal* baseline: no APIM, no Entra B2C, no AI Search / Foundry, no Service Bus, no Cosmos, no Key Vault-backed app secrets (the app has none). Those live in [azure-iac-reference](../../azure-iac-reference) (the maximalist showcase) and the [patterns catalog](../../azure-iac-patterns). Add them by composing the same platform modules when an app actually needs them.
