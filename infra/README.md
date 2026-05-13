# Critical Notice Ingestion - Infrastructure

This directory contains Bicep templates for deploying the Azure infrastructure supporting the Critical Notice ingestion pipeline.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        rg-dte-noticeapp-eus2-mx01                               │
│                                                                                 │
│  ┌───────────────────────┐  ┌────────────────────┐  ┌───────────────────────┐  │
│  │     Storage Acct      │  │     Key Vault      │  │    Logic Apps (x2)    │  │
│  │   stdtenotice...      │  │    kv-dte-...      │  │                       │  │
│  │                       │  │                    │  │  ┌─────────────────┐  │  │
│  │  • critical-notices/  │◀─│  • Connection      │◀─│  │ Scanner         │  │  │
│  │    ├─ raw-html/       │  │    strings         │  │  │ (15-min poll)   │  │  │
│  │    ├─ metadata/       │  │  • API keys        │  │  └────────┬────────┘  │  │
│  │    └─ parsed/         │  │                    │  │           │           │  │
│  │  • Hot/Cool/Archive   │  │                    │  │  ┌────────▼────────┐  │  │
│  │                       │  │                    │  │  │ Downloader      │  │  │
│  └───────────────────────┘  └────────────────────┘  │  │ (HTTP trigger)  │  │  │
│           │                                         │  └─────────────────┘  │  │
│           │                                         └───────────────────────┘  │
│           └──────────────────────┬──────────────────────────────────────────────┤
│                                  │                                              │
│  ┌──────────────────────────────────────────────────────────────────────────┐  │
│  │                         Data Factory                                      │  │
│  │                         adf-dte-noticeapp-eus2-mx01                       │  │
│  │  • AzureBlobStorage_ManagedIdentity linked service                        │  │
│  │  • FabricLakehouse_Mock linked service (configure post-deploy)            │  │
│  │  • IngestToFabric pipeline (copies parsed data to Fabric)                 │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                  │                                              │
└──────────────────────────────────┼──────────────────────────────────────────────┘
                                   │
                                   ▼
                       ┌──────────────────┐
                       │  Microsoft Fabric │
                       │  (External)       │
                       └──────────────────┘
```

## Resources Deployed

| Resource | Name | Purpose |
|----------|------|---------|
| Storage Account | `stdtenoticeappeus2mx01` | Raw HTML, metadata, parsed data |
| Key Vault | `kv-dte-noticeapp-eus2-mx01` | Connection strings, secrets |
| Logic App (Scanner) | `logic-dte-noticeapp-eus2-mx01-scanner` | Polls Enbridge every 15 min |
| Logic App (Downloader) | `logic-dte-noticeapp-eus2-mx01-downloader` | Downloads notices on demand |
| Data Factory | `adf-dte-noticeapp-eus2-mx01` | Push data to Fabric |

## Logic App Workflows

### CriticalNotice-Scanner

**Trigger:** Recurrence (every 15 minutes)

**Workflow:**
1. Initialize array of 25 business units (AG, BGS, BIG, BSP, EG, ET, GB, GPL, MCGP, MB, MNCA, MNUS, MR, NPC, NXCA, NXUS, SESH, SG, SR, STT, TE, TPGS, VCP, WE, WRGS)
2. For each business unit (5 concurrent):
   - HTTP GET `https://infopost.enbridge.com/infopost/noticesList.asp?pipe={unit}&type=CRI`
   - Get last-seen-keys blob from storage
   - Extract first `strKey1` from response
   - If new notice detected:
     - Call Downloader workflow via HTTP
     - Update last-seen-keys blob

**External Access:** Calls `infopost.enbridge.com` (no special permissions needed for HTTP actions)

### CriticalNotice-Downloader

**Trigger:** HTTP Request (called by Scanner)

**Input Schema:**
```json
{
  "businessUnit": "TE",
  "noticeId": "12345",
  "url": "https://infopost.enbridge.com/infopost/NoticeListDetail.asp?..."
}
```

**Workflow:**
1. HTTP GET the notice detail URL
2. Store raw HTML to `raw-html/{YYYY-MM-DD}/{businessUnit}/{noticeId}.html`
3. Store metadata JSON to `metadata/downloads/{date}/{unit}/{id}.json`
4. Return 200 OK with blob path

**Storage Access:** Uses managed identity with Storage Blob Data Contributor role

## Data Factory Pipelines

### IngestToFabric

Copies parsed Parquet files from Blob Storage to Fabric Lakehouse.

**Prerequisites:**
- Configure `FabricLakehouse_Mock` linked service with actual Fabric credentials
- Generate Parquet files in `parsed/` container (via separate parsing process)

### ArchiveRawHtml

Maintenance pipeline placeholder for archiving old HTML files.

## Prerequisites

- Azure CLI installed and authenticated
- AzCopy installed and authenticated (`azcopy login`) for backfill
- sqlcmd installed with AAD auth support (for SQL initialization)
- Contributor access to the target subscription
- Resource group `rg-dte-noticeapp-eus2-mx01` created

## Deployment

### Recommended: Single-Command Setup

Use the single setup script for a full environment build. It deploys infrastructure, builds and deploys the Logic App Standard package, uploads `config/sites.json`, initializes SQL when provided, and optionally seeds data.

```powershell
.\infra\scripts\setup-environment.ps1 `
  -ResourceGroupName rg-dte-noticeapp-eus2-mx01 `
  -Location eastus2 `
  -StorageAccountName stdtenoticeappeus2mx01 `
  -LogicAppName logic-dte-noticeapp-eus2-mx01 `
  -SeedMode Backfill `
  -SourceStorageAccountName <source-storage> `
  -SourceResourceGroupName <source-rg> `
  -Days 10 `
  -RunValidation
```

Seed modes:
- `None` (default) → config-only (no data seed/backfill).
- `LocalSeed` → import a local seed package (`-SeedPath` optional; defaults to `infra\seed-package`).
- `Backfill` → copy data directly from a source storage account (`-SourceStorageAccountName` required).

`Backfill` does not create local JSON files. To see and reuse the container data locally, run `export-seed-package.ps1` first; it creates the gitignored `infra\seed-package` folder.

Ensure the values you pass align with `main.parameters.json` (resource names and location).

### Local Validation (No Azure Calls)

Validate PowerShell script syntax locally before running deployments:

```powershell
.\infra\scripts\validate-local.ps1
# Optional: validate only the single setup script
.\infra\scripts\validate-local.ps1 -ScriptNames setup-environment.ps1
```

### Option 1: Azure CLI

```bash
# Login to Azure
az login

# Set subscription (if needed)
az account set --subscription "<subscription-id>"

# Create resource group (if it doesn't exist)
az group create \
  --name rg-dte-noticeapp-eus2-mx01 \
  --location eastus2

# Deploy infrastructure
az deployment group create \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --template-file main.bicep \
  --parameters main.parameters.json
```

### Option 2: PowerShell

```powershell
# Login to Azure
Connect-AzAccount

# Set subscription (if needed)
Set-AzContext -SubscriptionId "<subscription-id>"

# Create resource group (if it doesn't exist)
New-AzResourceGroup -Name "rg-dte-noticeapp-eus2-mx01" -Location "eastus2"

# Deploy infrastructure
New-AzResourceGroupDeployment `
  -ResourceGroupName "rg-dte-noticeapp-eus2-mx01" `
  -TemplateFile "main.bicep" `
  -TemplateParameterFile "main.parameters.json"
```

### Option 3: What-If (Preview Changes)

```bash
# Preview changes before deploying
az deployment group what-if \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --template-file main.bicep \
  --parameters main.parameters.json
```

## Redeploy + Backfill (Scripted)

The scripts under `infra\scripts` provide a repeatable redeploy sequence for Logic Apps Standard plus data backfill. Use these for advanced/manual steps when you don't want the single setup script.

```powershell
# 1) Deploy infrastructure (Bicep)
.\infra\scripts\deploy-infra.ps1 `
  -ResourceGroupName rg-dte-noticeapp-eus2-mx01 `
  -Location eastus2

# 2) Build and deploy workflow package (Logic Apps Standard)
.\infra\scripts\build-deployment-package.ps1 -Force
.\infra\scripts\deploy-workflows-standard.ps1 `
  -ResourceGroupName rg-dte-noticeapp-eus2-mx01 `
  -LogicAppName logic-dte-noticeapp-eus2-mx01

# 3) Seed config (sites registry)
.\infra\scripts\postdeploy-seed-config.ps1 `
  -StorageAccountName stdtenoticeappeus2mx01

# 4) Backfill storage (safe re-run, no overwrites)
.\infra\scripts\backfill-blobs.ps1 `
  -SourceStorageAccountName <source-storage> `
  -TargetStorageAccountName stdtenoticeappeus2mx01 `
  -SourceResourceGroupName <source-rg> `
  -TargetResourceGroupName rg-dte-noticeapp-eus2-mx01 `
  -Days 10
```

Notes:
- Scripts assume `az login` and `azcopy login` are completed.
- Backfill uses `--overwrite=false` to avoid clobbering newer target blobs.
- Adjust `-Days` to copy a larger date-folder window. `notices/` and `config/` are copied fully; `tracking/` and `discovery/` are copied when present.
- Historical raw HTML may be under `processed/raw/{source}/{YYYY-MM-DD}/...` after parser runs, so the backfill copies both `raw/` and `processed/raw/` date folders.

## Local Seed Package (Export/Import)

Use this workflow when you need a portable seed bundle from an existing storage account (offline transfer, review, or staged import). It mirrors the backfill categories but stages data on disk before upload.

The local JSON/data files are not committed to the repo and will not appear until this export command succeeds. The default output folder is `infra\seed-package`.

```powershell
# Export from source storage to local seed folder
.\infra\scripts\export-seed-package.ps1 `
  -StorageAccountName stdtenoticeappeus2mx01 `
  -SeedPath .\infra\seed-package `
  -Days 10

# Import into a newly deployed storage account (no overwrite by default)
.\infra\scripts\import-seed-package.ps1 `
  -StorageAccountName <target-storage> `
  -SeedPath .\infra\seed-package `
  -Days 10
```

Notes:
- Scripts assume `az login` and `azcopy login` are completed.
- Export captures full `notices/` and `config/`, optional `tracking/` and `discovery/`, last N date folders for `raw/`, `processed/raw/`, and `indices/daily/`, plus recent `parsed/` blobs (filtered by last-modified time via AzCopy).
- Import uses `--overwrite=false` unless `-Overwrite` is supplied.
- Default seed path is `infra\seed-package` (gitignored) or supply `-SeedPath`.
- Use `backfill-blobs.ps1` for direct storage-to-storage copy; use the seed package flow when you need local staging.

## Module Structure

```
infra/
├── main.bicep              # Main orchestration (deploys all modules)
├── main.parameters.json    # Environment-specific parameters
├── workflows/
│   ├── scanner.json        # CriticalNotice-Scanner workflow definition
│   └── downloader.json     # CriticalNotice-Downloader workflow definition
├── modules/
│   ├── storage.bicep       # Storage account, containers, lifecycle
│   ├── keyvault.bicep      # Key Vault with RBAC
│   ├── logicapp.bicep      # Logic Apps (Scanner + Downloader)
│   └── logicapp.bicep      # Logic Apps Standard (Scanner, Downloader, Parser)
└── README.md               # This file
```

## Storage Container Structure

The storage account creates a `critical-notices` container with logical folders:

```
critical-notices/
├── metadata/
│   ├── last-seen-keys/     # {unit}.json - tracks last strKey1 per unit
│   └── downloads/          # Download records
├── raw-html/               # Downloaded HTML files
│   └── {YYYY-MM-DD}/
│       └── {BusinessUnit}/
│           └── {NoticeID}.html
├── parsed/                 # Structured output (Parquet)
└── config/                 # Configuration files
```

## Lifecycle Policy

| Age | Tier | Notes |
|-----|------|-------|
| 0-30 days | Hot | Frequent access during polling |
| 30-90 days | Cool | Reduced access |
| 90+ days | Archive | Long-term retention |

## Managed Identities & RBAC

All services use **system-assigned managed identities** with least-privilege RBAC:

| Service | Role | Scope | Purpose |
|---------|------|-------|---------|
| Logic App (Scanner) | Storage Blob Data Owner | Resource Group | Read/write blobs and metadata |
| Logic App (Downloader) | Storage Blob Data Contributor | Resource Group | Write HTML blobs |
| Logic App (both) | Key Vault Secrets User | Key Vault | Access secrets |
| Data Factory | Storage Blob Data Contributor | Resource Group | Read blobs for Fabric ingestion |
| Data Factory | Key Vault Secrets User | Key Vault | Access Fabric credentials |

## Post-Deployment Steps

1. **Verify deployment outputs**
   ```bash
   az deployment group show \
     --resource-group rg-dte-noticeapp-eus2-mx01 \
     --name main \
     --query properties.outputs
   ```

2. **Initialize metadata blobs**
   - Create empty `last-seen-keys/{unit}.json` files for first run
   - Or let Scanner create them on first detection

3. **Configure Fabric linked service**
   - Navigate to Data Factory in Azure Portal
   - Edit `FabricLakehouse_Mock` linked service
   - Replace placeholder with actual Fabric workspace credentials

4. **Test the workflows**
   ```bash
   # Get downloader callback URL from outputs
   # Manually trigger scanner or wait for recurrence
   ```

## Cost Estimate

| Resource | SKU | Monthly Est. |
|----------|-----|--------------|
| Logic Apps Consumption (x2) | Pay-per-action | ~$5-15 |
| Storage Account | Hot, <10GB | ~$2 |
| Key Vault | Standard | ~$0.03 |
| Data Factory | Self-hosted | ~$5 |
| **Total** | | **~$12-22/month** |

## Troubleshooting

### Common Issues

1. **Storage account name taken**: Storage names are globally unique. Modify `storageAccountName` in parameters.

2. **Key Vault soft-delete conflict**: If redeploying after deletion, purge the soft-deleted vault:
   ```bash
   az keyvault purge --name kv-dte-noticeapp-eus2-mx01 --location eastus2
   ```

3. **Role assignment conflicts**: Existing role assignments will cause errors. Use `--mode Incremental` (default) to skip existing assignments.

4. **Workflow validation errors**: Check JSON syntax in `workflows/*.json` files. Use:
   ```bash
   az bicep build --file main.bicep
   ```

5. **HTTP connector fails to reach Enbridge**: Verify outbound network connectivity. No special firewall rules needed for Logic Apps Consumption.

## Related Documentation

- [Infrastructure Plan](../infrastructure-plan.md) - Full architecture details
- [Azure Logic Apps Consumption](https://docs.microsoft.com/azure/logic-apps/logic-apps-overview)
- [Bicep Documentation](https://docs.microsoft.com/azure/azure-resource-manager/bicep/)
- [Logic App Workflow Definition Schema](https://docs.microsoft.com/azure/logic-apps/logic-apps-workflow-definition-language)
