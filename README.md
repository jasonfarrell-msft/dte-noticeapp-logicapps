# Critical Notice Extraction Engine

A low-code/no-code Azure solution that extracts critical notices from natural gas pipeline operator websites and stores them in Microsoft Fabric for downstream analytics.

## Overview

This system monitors pipeline operator critical notices across multiple sources. Sites are declared in a small registry; their business units are **auto-discovered** at scan time from each site's landing-page dropdown. Today it covers:

- **Enbridge Infopost** (~25 business units) — HTML scraping
- **TC Energy Connects** (~12 business units) — JSON API

Critical notices are polled every 15 minutes, deduplicated, and stored in Azure Blob Storage with a unified schema ready for Microsoft Fabric ingestion.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AZURE LOGIC APPS                                │
│                                                                              │
│   ┌───────────────────┐    ┌──────────────────────────────────────────────┐  │
│   │  Recurrence       │───▶│  scanner (registry-driven, v4)               │  │
│   │  (Every 15 min)   │    │                                              │  │
│   └───────────────────┘    │  1. Read site registry from blob             │  │
│                            │  2. Per site: GET rootUrl                    │  │
│                            │  3. Discover BUs (inline JS)                 │  │
│                            │  4. Switch on parserModel:                   │  │
│                            │       html-table-v1 │ json-grid-v1          │  │
│                            └──────────────────────┬───────────────────────┘  │
│                                                   │                          │
│                            ┌──────────────────────▼───────────────────────┐  │
│                            │  downloader (source-agnostic)                │  │
│                            │  • Downloads raw HTML                        │  │
│                            │  • Creates canonical JSON metadata           │  │
│                            │  • Deduplicates via HEAD check               │  │
│                            └──────────────────────┬───────────────────────┘  │
└───────────────────────────────────────────────────┼──────────────────────────┘
                                                    │
                          ┌─────────────────────────┼─────────────────────────┐
                          │                         │                         │
                          ▼                         ▼                         ▼
              ┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
              │  Azure Blob      │      │  Microsoft       │      │  Azure AI        │
              │  Storage         │      │  Fabric          │      │  Foundry         │
              │  (Data Lake)     │      │  (Lakehouse)     │      │  (AI Parsing)    │
              └──────────────────┘      └──────────────────┘      └──────────────────┘
```

## Data Sources

Business units are **auto-discovered** at scan time from each site's landing-page dropdown. The registry only declares the site (`rootUrl`, `dropdownLabel`, `parserModel`) — no hand-maintained pipeline lists.

| Site | Parser Model | Discovery Source | Typical # BUs |
|------|--------------|------------------|---------------|
| `enbridge` (Enbridge Infopost) | `html-table-v1` | "Select Business Unit" `<ul>` (codes from `?Pipe=XX`) | ~25 |
| `tceconnects` (TC Energy Connects) | `json-grid-v1` | "Pipeline" `<ul>` (codes + assetId from `changeAsset(...)`) | ~12 (deduped) |

If discovery fails or returns suspiciously few entries (< 50% of last good run), the scanner falls back to the cached list at `critical-notices/discovery/{siteId}.json`.

## Storage Structure

```
critical-notices/
├── notices/                     # Canonical notice metadata (JSON) — written by downloader
│   ├── enbridge/{pipeline}/
│   └── tceconnects/{pipeline}/
├── raw/                         # Raw HTML/JSON payload as captured from the source — written by downloader
│   ├── enbridge/{date}/{pipeline}/
│   └── tceconnects/{date}/{pipeline}/
├── parsed/                      # AI-extracted structured JSON — written by parser, consumed by ADF → Fabric
│   ├── enbridge/{pipeline}/{noticeId}.json
│   └── tceconnects/{pipeline}/{noticeId}.json
├── failed-parsing/              # Quarantine for parser failures (one file per attempt, timestamped)
│   ├── enbridge/{pipeline}/
│   └── tceconnects/{pipeline}/
├── tracking/                    # Per-pipeline state + scan-summary.json (scanner + downloader heartbeat)
├── discovery/                   # Cached BU lists per site (fallback if live discovery fails)
│   ├── enbridge.json
│   └── tceconnects.json
├── indices/daily/               # Daily indexes for reporting
└── config/sites.json            # Site registry (read by scanner each run)
```

Each `parsed/{source}/{pipeline}/{noticeId}.json` document contains:

```jsonc
{
  "metadata": {
    "source":        "enbridge | tceconnects",
    "pipeline":      "AG | ANR | ...",
    "noticeId":      "172843",
    "rawBlobPath":   "raw/enbridge/2026-04-18/AG/172843.html",
    "parsedAt":      "2026-04-20T18:33:12Z",
    "foundryModel":  "gpt-5.2",
    "tokensUsed":    5313
  },
  "extracted": {
    "title":              "...",
    "noticeType":         "Maintenance | Capacity Constraint | Operational Alert | Force Majeure | Other",
    "status":             "Initiate | Supersede | Cancel",
    "postedDate":         "ISO 8601",
    "effectiveDate":      "ISO 8601",
    "endDate":            "ISO 8601 | null",
    "description":        "Cleaned plain-text body",
    "affectedLocations":  ["..."],
    "responseRequired":   true
  }
}
```

The `parsed/` folder is the **handoff point to Microsoft Fabric** — the ADF `IngestToFabric` pipeline copies new files from this prefix into the Lakehouse. The parser is idempotent: a HEAD check against `parsed/{source}/{pipeline}/{noticeId}.json` causes already-processed raws to be skipped on subsequent runs.

## Infrastructure

The solution deploys to Azure with VNet isolation:

| Resource | Purpose |
|----------|---------|
| Logic Apps (Standard) | Scanner and downloader workflows |
| Azure Blob Storage | Data lake for notices |
| Azure Key Vault | Secrets management |
| Azure AI Foundry | AI-powered HTML parsing (Phase 3) |
| Azure Data Factory | Parsed → SQL landing (`LandParsedToSql`) and Fabric data movement |
| Azure SQL Database | Relational landing for parsed notices (`noticesdb.dbo.notices`, serverless) |
| Virtual Network | Network isolation with private endpoints |

**Estimated cost:** ~$180/month

## Deployment

This is a standalone Azure deployment — no external dependencies, no Fabric required to get started. Follow these steps in order.

### Prerequisites

| Prerequisite | Install / verify |
|---|---|
| Azure CLI ≥ 2.57 | `az version` — [install](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Bicep CLI (bundled with Azure CLI) | `az bicep version` |
| sqlcmd (for SQL post-deploy DDL) | `winget install Microsoft.Sqlcmd` or [download](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) |
| Azure subscription | Contributor + User Access Administrator on the target subscription |
| Azure Active Directory | An AAD user or group object ID to use as the SQL admin |

> **Note:** All resources are provisioned with AAD-only authentication. No passwords or connection strings are stored.

---

### Step 1 — Clone and configure

```bash
git clone https://github.com/<org>/critical-notice-parsing.git
cd critical-notice-parsing
```

Edit **`infra/main.parameters.json`** and replace the placeholder values for your environment:

```jsonc
{
  "parameters": {
    "location":             { "value": "eastus2" },          // Azure region
    "storageAccountName":   { "value": "st<unique>eus2" },   // globally unique, 3-24 chars
    "keyVaultName":         { "value": "kv-<name>-eus2" },   // globally unique
    "logicAppName":         { "value": "logic-<name>-eus2" },
    "dataFactoryName":      { "value": "adf-<name>-eus2" },
    "sqlServerName":        { "value": "sql-<name>-eus2" },  // globally unique
    "sqlDatabaseName":      { "value": "noticesdb" },
    "sqlAdminAadObjectId":  { "value": "<your-aad-object-id>" },  // run: az ad signed-in-user show --query id -o tsv
    "sqlAdminAadLoginName": { "value": "<your-upn@domain.com>" }
  }
}
```

To find your AAD object ID:

```bash
az ad signed-in-user show --query id -o tsv
```

---

### Step 2 — Authenticate and select subscription

```bash
az login
az account set --subscription "<subscription-id>"

# Verify you have Contributor on the target subscription
az role assignment list \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --subscription "<subscription-id>" \
  --query "[?roleDefinitionName=='Contributor']" \
  -o table
```

---

### Step 3 — Create the resource group

```bash
az group create \
  --name rg-dte-noticeapp-eus2-mx01 \
  --location eastus2
```

---

### Step 4 — Preview the deployment (optional but recommended)

```bash
az deployment group what-if \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json
```

Review the planned changes. Expect ~20 resources: VNet, storage account, Key Vault, App Service Plan, Logic Apps Standard, Data Factory, AI Foundry (Cognitive Services), SQL server + database, private endpoints, and role assignments.

---

### Step 5 — Deploy infrastructure

```bash
az deployment group create \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json \
  --only-show-errors
```

Typical deploy time: **8–12 minutes**. On success, `provisioningState` returns `Succeeded`.

> **Subscription-level role assignments:** The template assigns the Logic App's managed identity `Data Factory Contributor` on the ADF resource (so the parser can trigger pipelines). If the deploying principal lacks `Microsoft.Authorization/roleAssignments/write`, remove the role assignment block from `main.bicep` and add it manually after deploy:
>
> ```bash
> ADF_ID=$(az datafactory show -g rg-dte-noticeapp-eus2-mx01 -n adf-<name>-eus2 --query id -o tsv)
> PARSER_MI=$(az resource show -g rg-dte-noticeapp-eus2-mx01 --resource-type Microsoft.Web/sites -n logic-<name>-eus2 --query identity.principalId -o tsv)
> az role assignment create --role "Data Factory Contributor" --assignee $PARSER_MI --scope $ADF_ID
> ```

---

### Step 6 — Apply SQL DDL and grants (one-time, post-deploy)

The SQL database is provisioned but empty. Run DDL as the AAD admin you set in `sqlAdminAadObjectId`.

> **`sqlcmd` AAD authentication note:** Windows Integrated Authentication (`-G` flag) requires the Azure CLI session user to match the SQL AAD admin. If you see `Login failed` with `-G`, use the PowerShell workaround below.

**Option A — sqlcmd (simplest if auth works)**

```bash
SQL_SERVER="sql-<name>-eus2.database.windows.net"

# Create tables and stored proc
sqlcmd -S $SQL_SERVER -d noticesdb -G -i infra/sql/notices.sql

# Grant ADF managed identity access
ADF_NAME="adf-<name>-eus2"
sed "s/<ADF_NAME>/$ADF_NAME/g" infra/sql/grants.sql | \
  sqlcmd -S $SQL_SERVER -d noticesdb -G
```

**Option B — PowerShell with access token (more reliable)**

```powershell
$server   = "sql-<name>-eus2.database.windows.net"
$adfName  = "adf-<name>-eus2"
$token    = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)

Add-Type -AssemblyName System.Data
$conn = New-Object System.Data.SqlClient.SqlConnection(
  "Server=tcp:$server,1433;Initial Catalog=noticesdb;Encrypt=True;TrustServerCertificate=False;")
$conn.AccessToken = $token
$conn.Open()

# Apply DDL (notices.sql + grants.sql)
foreach ($file in @("infra\sql\notices.sql", "infra\sql\grants.sql")) {
  $sql = (Get-Content -Raw $file) -replace '<ADF_NAME>', $adfName
  foreach ($batch in ($sql -split "(?im)^\s*GO\s*$")) {
    if ($batch.Trim()) {
      $cmd = $conn.CreateCommand(); $cmd.CommandText = $batch
      [void]$cmd.ExecuteNonQuery()
    }
  }
}
$conn.Close()
Write-Host "DDL applied successfully"
```

---

### Step 7 — Upload the site registry

The scanner reads the site registry from blob storage at runtime. Upload the seed file:

```bash
az storage blob upload \
  --account-name st<unique>eus2 \
  --container-name critical-notices \
  --name config/sites.json \
  --file infra/config/sites.json \
  --auth-mode login \
  --overwrite
```

---

### Step 8 — Deploy Logic App workflows

The Logic App workflows are defined as JSON files under `infra/workflows/`. Upload them via the Azure CLI or directly through the Logic Apps portal.

First, rebuild the scanner workflow (embeds the inline discovery JS):

```bash
node infra/workflows/_build_scanner.js
node infra/workflows/_build_parser.js
```

Then upload each workflow definition:

```bash
LOGIC_APP="logic-<name>-eus2"
RG="rg-dte-noticeapp-eus2-mx01"

for wf in scanner downloader parser; do
  az logicapp workflow create \
    --resource-group $RG \
    --name $LOGIC_APP \
    --workflow-name $wf \
    --definition @infra/workflows/${wf}.json
done
```

> Alternatively, open the Logic App in the Azure portal, navigate to **Workflows**, and use the **Code view** to paste each JSON definition.

---

### Step 9 — Smoke test

**Test ADF pipeline (backfill):**

```bash
az datafactory pipeline create-run \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --factory-name adf-<name>-eus2 \
  --name LandParsedToSql \
  --parameters '{"sourceFolder":"parsed","fileName":""}'
```

Or via REST (more reliable when `az datafactory` times out):

```powershell
$mgmtToken = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$sub = "<subscription-id>"
$rg  = "rg-dte-noticeapp-eus2-mx01"
$adf = "adf-<name>-eus2"

$resp = Invoke-RestMethod `
  -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.DataFactory/factories/$adf/pipelines/LandParsedToSql/createRun?api-version=2018-06-01" `
  -Method Post `
  -Headers @{ Authorization = "Bearer $mgmtToken"; "Content-Type" = "application/json" } `
  -Body '{"sourceFolder":"parsed","fileName":""}'

Write-Host "Run ID: $($resp.runId)"
```

**Verify SQL landing:**

```powershell
$token = (az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)
$conn = New-Object System.Data.SqlClient.SqlConnection(
  "Server=tcp:sql-<name>-eus2.database.windows.net,1433;Initial Catalog=noticesdb;Encrypt=True;TrustServerCertificate=False;")
$conn.AccessToken = $token; $conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT COUNT(*) AS notices FROM dbo.notices; SELECT COUNT(*) AS locations FROM dbo.notice_locations;"
$rdr = $cmd.ExecuteReader()
while ($rdr.Read()) { Write-Host "$($rdr.GetName(0)) = $($rdr.GetValue(0))" }
$conn.Close()
```

Expected output: `notices = <N>`, `locations = <N>` (populated once the parser has run at least once).

---

### Step 10 — Enable the scanner trigger

In the Azure portal, navigate to **Logic Apps → logic-\<name\>-eus2 → Workflows → scanner → Designer** and **enable** the recurrence trigger. It polls every 15 minutes.

Alternatively via CLI:

```bash
az logicapp workflow show \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --name logic-<name>-eus2 \
  --workflow-name scanner
# Then toggle the trigger via the portal; CLI trigger-management is read-only for Standard plans.
```

---

### Resource naming conventions

All resource names in `main.parameters.json` must be **globally unique** across Azure (storage accounts, Key Vaults, SQL servers). A safe pattern:

```
st{shortname}{region}{seq}        # storage: st<8chars max> — no hyphens
kv-{project}-{region}-{seq}       # Key Vault
sql-{project}-{region}-{seq}      # SQL server
adf-{project}-{region}-{seq}      # Data Factory
```

---

### Estimated costs

| Resource | SKU | Est. $/month |
|---|---|---|
| Logic Apps Standard | WS1 | ~$75 |
| Azure Blob Storage | LRS Hot | ~$5 |
| Azure Key Vault | Standard | ~$5 |
| Azure AI Foundry | S0 | ~$20 (usage-based) |
| Azure Data Factory | Serverless pipelines | ~$5 (usage-based) |
| Azure SQL Database | GP_S_Gen5_1, serverless, 60-min auto-pause | ~$10 |
| Virtual Network + Private Endpoints | — | ~$15 |
| **Total** | | **~$135–$180/month** |

Costs vary with notice volume. The scanner runs every 15 minutes but only downloads new notices; SQL auto-pauses after 60 minutes of inactivity.

---

### Teardown

```bash
az group delete \
  --name rg-dte-noticeapp-eus2-mx01 \
  --yes --no-wait
```

This removes all resources in the group. Key Vault has soft-delete enabled (90-day retention); if you redeploy with the same vault name, purge it first:

```bash
az keyvault purge --name kv-<name>-eus2 --location eastus2
```

## Configuration

The site registry lives in [`infra/config/sites.json`](infra/config/sites.json) and is uploaded to blob storage; the scanner reads it at runtime. Each site declares only what it needs to be discovered and dispatched — **no hand-maintained business-unit lists**:

```jsonc
{
  "version": "3.0.0",
  "sites": [
    {
      "id": "enbridge",
      "enabled": true,
      "parserModel": "html-table-v1",
      "discovery": {
        "rootUrl": "https://infopost.enbridge.com/infopost/",
        "dropdownLabel": "Select Business Unit"
      },
      "config": {
        "listUrlPattern":   "https://infopost.enbridge.com/infopost/{code}NoticesList.asp?strKey1=",
        "detailUrlPattern": "https://infopost.enbridge.com/infopost/{code}NoticesDetail.asp?strKey1={noticeId}",
        "noticeIdToken":    "strKey1"
      }
    },
    {
      "id": "tceconnects",
      "enabled": true,
      "parserModel": "json-grid-v1",
      "discovery": {
        "rootUrl": "https://www.tceconnects.com/",
        "dropdownLabel": "Pipeline"
      },
      "config": {
        "listUrlPattern":   "https://www.tceconnects.com/Notices/GetNotices?assetId={assetId}&...",
        "detailUrlPattern": "https://www.tceconnects.com/Notices/Detail?assetId={assetId}&noticeId={noticeId}"
      }
    }
  ]
}
```

## Canonical Data Schema

All notices are normalized to this unified schema:

| Field | Type | Description |
|-------|------|-------------|
| source | STRING | `enbridge` or `tceconnects` |
| pipeline | STRING | Business unit code (e.g., TE, ANR) |
| pipelineName | STRING | Full pipeline company name |
| noticeId | STRING | Unique notice identifier |
| noticeType | STRING | Maintenance, Capacity Constraint, etc. |
| status | STRING | Initiate, Supersede, Cancel |
| isCritical | BOOLEAN | Critical notice flag |
| title | STRING | Notice subject/title |
| postedDate | DATETIME | When notice was posted |
| effectiveDate | DATETIME | When notice takes effect |
| endDate | DATETIME | When notice expires |
| rawBlobPath | STRING | Path to raw HTML in storage |
| scrapedAt | DATETIME | When captured |

## How It Works

The scanner is **registry-driven and self-discovering**. Each scan run:

1. **Scanner** triggers every 15 minutes
2. Reads the **site registry** from blob `critical-notices/config/sites.json`
3. Filters to `enabled: true` sites
4. **Per site**: HTTP GET `discovery.rootUrl`, then runs an inline **Execute JavaScript Code** action that scrapes the dropdown identified by `discovery.dropdownLabel` and extracts business units using a per-`parserModel` regex strategy (Enbridge: `?Pipe=XX` from anchor href; TCE: `changeAsset(assetId, 'Name (CODE)')`). Results are deduped by code.
5. **Sanity check**: if discovery returned 0 BUs *or* fewer than 50% of the last cached count, the scanner uses the previously cached list at `discovery/{siteId}.json`. On a successful live discovery, the cache is rewritten.
6. Dispatches via `Switch` on `parserModel` (`html-table-v1` | `json-grid-v1`) over the discovered BU list, fetches each notice list, HEAD-checks blob storage to skip already-captured notices.
7. **Downloader** fetches new notices only and writes raw + canonical JSON.
8. Tracking + scan-summary blobs are updated for observability.
9. Data Factory pushes to Microsoft Fabric Lakehouse.

### Adding a new site (client-friendly)

A new site requires only **three fields** in the registry:

```jsonc
{
  "id": "newsite",
  "name": "New Pipeline Operator",
  "enabled": true,
  "parserModel": "html-table-v1",
  "discovery": {
    "rootUrl": "https://newsite.example.com/infopost/",
    "dropdownLabel": "Select Business Unit"
  },
  "config": {
    "listUrlPattern":   "https://newsite.example.com/infopost/{code}List.asp?strKey1=",
    "detailUrlPattern": "https://newsite.example.com/infopost/{code}Detail.asp?strKey1={noticeId}",
    "noticeIdToken":    "strKey1"
  }
}
```

If the new site uses an existing `parserModel` → no workflow change is needed; just upload the registry blob. If it requires a new shape, add a case to `Dispatch_By_ParserModel` in `scanner.json` and add a regex branch in `infra/workflows/discover-bus.js`.

### Deploying registry changes

The registry is read at runtime from blob storage — no Logic App redeploy is required. Upload the seed/updated file with:

```bash
az storage blob upload \
  --account-name stdtenoticeappeus2mx01 \
  --container-name critical-notices \
  --name config/sites.json \
  --file infra/config/sites.json \
  --auth-mode login \
  --overwrite
```

## Project Structure

```
├── infra/
│   ├── main.bicep                    # Main deployment orchestration
│   ├── main.parameters.json          # Environment parameters
│   ├── config/
│   │   └── sites.json                # Site registry (uploaded to blob; read by scanner at runtime)
│   ├── sql/
│   │   ├── notices.sql               # Idempotent DDL for dbo.notices (run post-deploy)
│   │   └── grants.sql                # Grants ADF MI db_datareader/db_datawriter (run post-deploy)
│   ├── modules/
│   │   ├── storage.bicep             # Blob Storage with lifecycle
│   │   ├── keyvault.bicep            # Key Vault with RBAC
│   │   ├── logicapp-standard.bicep   # Logic Apps Standard
│   │   ├── vnet.bicep                # Virtual Network
│   │   ├── private-endpoints.bicep   # Private endpoints
│   │   ├── foundry.bicep             # Azure AI Foundry
│   │   ├── sql.bicep                 # Azure SQL serverless (parsed-notice landing)
│   │   └── datafactory.bicep         # Data Factory (incl. LandParsedToSql pipeline)
│   └── workflows/
│       ├── scanner.json              # Scanner workflow (v4 — discovery + dispatch)
│       ├── discover-bus.js           # Inline JS used by scanner discovery action
│       ├── _build_scanner.js         # Build helper: embeds discover-bus.js into scanner JSON
│       ├── downloader.json           # Downloader workflow definition
│       └── parser.json               # AI parser workflow (triggers ADF LandParsedToSql)
├── infrastructure-plan.md            # Detailed architecture documentation
└── README.md                         # This file
```

## Implementation Status

- [x] Site analysis and API discovery
- [x] Unified storage schema design
- [x] Multi-site scanner workflow (registry-driven, parserModel dispatch, auto-discovery)
- [x] Multi-site downloader workflow
- [x] VNet-isolated infrastructure (Bicep)
- [x] Azure AI Foundry integration
- [x] Initial deployment + smoke test (Enbridge 25 BUs, TCE 12 unique BUs verified)
- [x] **Azure SQL landing** — `dbo.notices` in `noticesdb` on `sql-dte-noticeapp-eus2-mx01`, ADF `LandParsedToSql` pipeline triggered per-file by parser Logic App
- [ ] Fabric Lakehouse connection
- [ ] AI-powered HTML parsing (Phase 3)

## Azure SQL Landing (Parsed → `dbo.notices`)

After the parser writes a parsed JSON blob, it `POST`s to ADF's `createRun` REST endpoint using its system-assigned managed identity. The `LandParsedToSql` pipeline runs two activities:

1. **CopyParsedJsonToSql** — upserts each notice into `dbo.notices` keyed on `(source, pipeline, noticeId)`. The `affectedLocations` JSON array is stored as a serialized JSON string via `mapComplexValuesToString`.
2. **FlattenAffectedLocations** — calls `dbo.usp_FlattenAffectedLocations` which uses `OPENJSON` to fan the locations array out into `dbo.notice_locations` (one row per location per notice). Idempotent: scoped to the single notice for per-file runs; rebuilds the full child table for backfill runs.

**Backfill trigger** (reprocesses all `parsed/**/*.json`):

```bash
az datafactory pipeline create-run \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --factory-name adf-dte-noticeapp-eus2-mx01 \
  --name LandParsedToSql \
  --parameters '{"sourceFolder":"parsed","fileName":""}'
```

**Schema:**

| Table | Rows (approx) | Notes |
|---|---|---|
| `dbo.notices` | 1 per notice | PK: `(source, pipeline, noticeId)` |
| `dbo.notice_locations` | N per notice | FK → notices with cascade delete |

## Documentation

- [Infrastructure Plan](infrastructure-plan.md) — Full architecture details and decisions
- [Infra README](infra/README.md) — Deployment and troubleshooting guide

## Scope

**This system handles ingestion only:**
- ✅ Poll multiple pipeline operator websites
- ✅ Detect and capture new critical notices
- ✅ Store raw content and normalized metadata
- ✅ Maintain daily indexes for efficient queries

**Out of scope (handled by Fabric team):**
- ❌ Alerting and notifications
- ❌ Dashboards and reporting
- ❌ Advanced data transformation

## License

Internal use only.
