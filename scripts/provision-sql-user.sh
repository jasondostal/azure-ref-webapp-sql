#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# provision-sql-user.sh
#
# Create (idempotently) the app's managed-identity DB user in a PRIVATE Azure
# SQL database, and grant it data read/write. This is the step that makes the
# passwordless connection actually work — without it the app authenticates as
# its MI but has no login on the database.
#
# WHY IT RUNS ON THE SELF-HOSTED AGENT: the SQL server has public access
# disabled, reachable only via its private endpoint inside the VNet. A
# Microsoft-hosted agent cannot route to it; this script must run on the
# VNet-injected self-hosted pool.
#
# AUTH: connects using ActiveDirectoryDefault, which picks up the az CLI login
# that the AzureCLI@2 pipeline task established (the deploy service principal).
# That SP MUST be a member of the SQL admin Entra group set in main.bicep, or
# the CREATE USER will fail with "principal is not a server admin".
#
# Usage: provision-sql-user.sh <sqlFqdn> <dbName> <appName> <resourceGroup>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SQL_FQDN="${1:?sqlFqdn required}"
DB_NAME="${2:?dbName required}"
APP_NAME="${3:?appName (App Service) required}"
RESOURCE_GROUP="${4:?resourceGroup required}"

echo "==> Resolving managed-identity object ID for App Service '${APP_NAME}'"
APP_OID="$(az webapp identity show \
  --name "${APP_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query principalId -o tsv)"
if [[ -z "${APP_OID}" ]]; then
  echo "ERROR: ${APP_NAME} has no system-assigned identity." >&2
  exit 1
fi
echo "    object ID: ${APP_OID}"

# Azure SQL maps a managed-identity login to a contained user by a SID derived
# from the identity's CLIENT (application) ID — NOT its object ID. So resolve
# the appId and compute the SID. (Creating the user WITH OBJECT_ID = <objectId>
# produces a non-matching SID and the app fails with a confusing
# "Login failed for token-identified principal".)
APP_APPID="$(az ad sp show --id "${APP_OID}" --query appId -o tsv)"
APP_SID="$(python3 -c 'import uuid,sys; print("0x"+uuid.UUID(sys.argv[1]).bytes_le.hex().upper())' "${APP_APPID}")"
echo "    client ID: ${APP_APPID}  →  SID ${APP_SID}"

# Ensure go-sqlcmd is available (the platform agent image ships .NET SDK + az
# CLI but not sqlcmd). Single static binary — pinned for reproducibility.
SQLCMD="${SQLCMD_BIN:-$(command -v sqlcmd || true)}"
if [[ -z "${SQLCMD}" ]]; then
  echo "==> Fetching go-sqlcmd"
  SQLCMD_VERSION="v1.8.2"
  curl -sSL -o /tmp/sqlcmd.tar.bz2 \
    "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-amd64.tar.bz2"
  tar -xjf /tmp/sqlcmd.tar.bz2 -C /tmp sqlcmd
  SQLCMD="/tmp/sqlcmd"
  chmod +x "${SQLCMD}"
fi

# CREATE USER ... WITH SID = <appId-derived>, TYPE = E binds the contained user
# to the MI's token SID directly — no Directory Readers role on the SQL server
# required (the by-name FROM EXTERNAL PROVIDER form would need it).
read -r -d '' TSQL <<SQL || true
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'${APP_NAME}')
BEGIN
    CREATE USER [${APP_NAME}] WITH SID = ${APP_SID}, TYPE = E;
END
ALTER ROLE db_datareader ADD MEMBER [${APP_NAME}];
ALTER ROLE db_datawriter ADD MEMBER [${APP_NAME}];
SQL

echo "==> Applying DB user + role grants on ${DB_NAME}"
"${SQLCMD}" \
  --server "tcp:${SQL_FQDN},1433" \
  --database "${DB_NAME}" \
  --authentication-method ActiveDirectoryDefault \
  --query "${TSQL}" \
  --exit-on-error

echo "==> Done: [${APP_NAME}] provisioned on ${DB_NAME}"
