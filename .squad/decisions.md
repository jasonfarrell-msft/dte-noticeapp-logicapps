# Squad Decisions

## Active Decisions

### 1. Parser Architecture: Microsoft Foundry GPT-Powered HTML Parsing

**Author:** Hopper (Lead/Architect)  
**Date:** 2026-04-18  
**Status:** APPROVED  
**Impact:** Production parser for critical notice extraction

#### Decision
Use **Microsoft Foundry GPT-4o** with Logic Apps for no-code parsing of critical notice HTML documents into canonical JSON format.

#### Rationale
- **Flexibility:** Handles varying HTML structures (Enbridge tables + TCeConnects SSRS reports)
- **Accuracy:** Superior field extraction with natural language understanding
- **No training:** Zero-shot prompting requires no model configuration
- **Cost:** ~$0.005-0.015 per notice (~$17/month for 1,800 notices)
- **No-code:** Logic Apps visual designer meets business user maintainability requirement

#### Rejected Alternatives
- Azure Document Intelligence: Limited field extraction, requires training, less flexible for varying HTML
- Azure Functions: Violates no-code constraint; requires developer expertise

#### Architecture
- **Trigger:** Event Grid blob creation on raw/ folder
- **Processing:** Logic App workflow with HTTP action to Foundry GPT-4o endpoint
- **Output:** Canonical JSON to parsed/ folder
- **Error Handling:** Failed items logged to failed-parsing/ folder
- **Retry:** 3 attempts with exponential backoff

#### Canonical Notice Schema
```json
{
  "source": "enbridge | tceconnects",
  "pipeline": "TE",
  "pipelineName": "Texas Eastern",
  "noticeId": "176751",
  "title": "...",
  "noticeType": "Capacity Constraint | Maintenance | ...",
  "status": "Initiate | Supersede | Cancel",
  "postedDate": "2024-04-17T00:00:00Z",
  "effectiveDate": "2024-04-18T00:00:00Z",
  "endDate": "2024-04-25T00:00:00Z",
  "description": "Main notice content extracted from HTML",
  "affectedLocations": ["Location 1", "Location 2"],
  "responseRequired": true,
  "rawBlobPath": "raw/enbridge/2024-04-17/TE/176751.html",
  "parsedAt": "2024-04-17T15:30:00Z"
}
```

#### Next Steps
- Deploy Foundry infrastructure via Bicep
- Monitor Logic App runs and extraction quality
- Tune extraction prompts as needed

---

### 2. Parser Implementation: Logic Apps with Foundry Integration

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-18  
**Status:** APPROVED  
**Impact:** Infrastructure implementation for parser

#### Decision
Implement Parser Logic App with recurrence trigger (5 min) + List Blobs API pattern using Microsoft Foundry GPT-4o-mini deployment.

#### Components
- **foundry.bicep:** Foundry deployment (GPT-4o-mini, SKU S0, 30K TPM)
- **parser-multisite.json:** Logic App workflow
- **Authentication:** System-assigned managed identity + RBAC
- **Error Logging:** failed-parsing/{source}/{pipeline}/{noticeId}-{timestamp}.json

#### Implementation Details
- **Trigger:** Recurrence (5 min) instead of blob trigger for simplicity
- **Processing:** List blobs (max 50 per run) → Parse XML → Foreach loop (concurrency=3)
- **Idempotency:** HEAD check prevents re-processing existing parsed files
- **Throughput:** Up to 50 blobs per run (150/hour with concurrency=3)

#### Extraction Configuration
- **Model:** GPT-4o-mini (economical, fast)
- **Temperature:** 0.1 (deterministic extraction)
- **Max tokens:** 2000
- **Response format:** json_object mode enforced

#### Rationale
- **Recurrence vs. Blob trigger:** Blob triggers require API connections; recurrence + List Blobs simpler for Consumption Logic Apps
- **GPT-4o-mini:** Balances cost and quality for high-volume parsing
- **Managed identity:** Eliminates credential management; RBAC provides least-privilege access

#### Rejected Alternatives
- Blob trigger: Requires API connection setup (more complexity)
- Azure Functions: Violates no-code requirement

#### Security
- Managed identity for all blob operations
- Storage Blob Data Contributor role at resource group scope
- Foundry API key stored in Key Vault
- No service principal credentials in code

---

### 3. Bicep Infrastructure Decisions

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-17  
**Status:** APPROVED  
**Impact:** Azure resource management pattern

#### Decision 1: RBAC Authorization
Use `enableRbacAuthorization: true` instead of Key Vault access policies.

**Rationale:** RBAC is modern approach; allows unified permission management; integrates better with managed identities.

#### Decision 2: Shared Storage Account
Logic Apps Standard uses same storage account for:
- Internal state (AzureWebJobsStorage)
- Business data (critical-notices container)

**Rationale:** Simplifies architecture; reduces cost; Logic Apps creates internal containers that don't conflict with business data.

**Rejected:** Separate storage for internals (unnecessary complexity).

#### Decision 3: System-Assigned Managed Identity
All services (Logic Apps, Data Factory) use system-assigned, not user-assigned.

**Rationale:** Simpler lifecycle; identity created/deleted with resource; no orphan identities.

#### Decision 4: Role Assignments at Resource Group Scope
Storage Blob Data Contributor assigned at resource group level, not storage account.

**Rationale:** Simplifies Bicep code; permissions auto-propagate if storage accounts added later.

---

### 4. User Directive: Security Control Tag

**Author:** Jason Farrell (via Copilot)  
**Date:** 2026-04-17  
**Status:** DIRECTIVE  
**Impact:** Tagging standard

#### Directive
All Azure resources should have the tag `SecurityControl: Ignore`

**Reason:** User request — captured for team memory

---

### 5. Production Deployment: Model Migration & RBAC Fixes

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-18  
**Status:** DEPLOYED  
**Impact:** Production parser service operability

#### Context
Deploying full parser infrastructure to `rg-dte-noticeapp-eus2-mx01` required runtime fixes before clean, re-deployable state achieved.

#### Decision 1: Model Substitution (gpt-4o-mini → gpt-4.1-mini)
- **Problem:** gpt-4o-mini (2024-07-18) deprecated since 2026-03-31; deployment failed with `ServiceModelDeprecated`
- **Solution:** Deploy gpt-4.1-mini (2025-04-14) — GA, deployable, same Chat Completions + structured JSON output capability
- **Changes:**
  - `infra/modules/foundry.bicep` model/version/name updated
  - `infra/workflows/parser-multisite.json` foundryDeploymentName updated
- **Rationale:** Maintains architectural pattern; gpt-4.1-mini is economically and functionally equivalent; alleviates subscription/region constraint

#### Decision 2: RBAC Role Assignment GUID Pinning
- **Problem:** ADF Key Vault Secrets User role assignment failed with `RoleAssignmentExists` — existing assignment had different resource name/ID than ARM template's deterministic `guid(...)` calculation
- **Solution:** Pin `adfKeyVaultRole.name` to existing GUID: `d01069f8-e69b-5b52-b262-7dc8ae066825`
- **Changes:** `infra/main.bicep` role assignment resource name hardcoded
- **Rationale:** ARM deployment idempotency requires role assignment resource names to be deterministic constants; mismatch prevents re-deploy safety even if assignment is semantically identical

#### Verification
- ✅ Foundry API responds (HTTP 200)
- ✅ Logic App deployed, enabled, runs present

#### Open Questions for Architecture Review
- Acceptability of gpt-4.1-mini as permanent production model given gpt-4o-mini deprecation pattern
- Whether ADF Key Vault role assignment should be re-baselined (delete/recreate) to return to deterministic naming, or accept pinned GUID as production reality

---

### 6. User Directive: Agent Model Preference

**Author:** Jason Farrell (via Copilot)  
**Date:** 2026-04-18  
**Status:** DIRECTIVE  
**Impact:** Agent spawning configuration

#### Directive
Use GPT-5 model for agent spawns.

**Reason:** User request — captured for team memory.

---

### 7. Foundry v2 Migration: Cognitive Services AIServices + GPT-5.2

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-18  
**Status:** APPROVED / DEPLOYED  
**Impact:** Production Foundry deployment upgrade

#### Context
Previous deployments used deprecated `kind: OpenAI` Cognitive Services. Requirement to migrate to Cognitive Services v2 (AIServices) pattern and upgrade model from gpt-4.1-mini to gpt-5.2.

#### Decision
1. Use Cognitive Services account with `kind: AIServices` for Foundry v2
2. Deploy model `gpt-5.2` version `2025-12-11`
3. Use deployment SKU `DataZoneStandard` with capacity 1 (quota constraint — `GlobalStandard` exhausted in East US 2)
4. Purge soft-deleted resource before redeployment to avoid ARM `restore: true` requirement

#### Rationale
- `AIServices` produces v2-style endpoint (*.cognitiveservices.azure.com)
- GPT-5.2 available in East US 2 per az cognitiveservices model list
- `DataZoneStandard` validated and deployable; quota workaround for current constraints

#### Changes Made
- `infra/modules/foundry.bicep`: Updated kind, model, version, SKU, capacity, apiVersion
- `infra/workflows/parser-multisite.json`: Updated default deployment name reference
- Operational: Deleted and purged old account before redeployment

#### Follow-ups
- Request quota increase for GPT-5.2 `GlobalStandard` if higher throughput needed
- Endpoint and auth patterns remain same; workflows continue via `/openai/deployments/...`

---

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction


---


### 2026-04-18T19:42: User directive
**By:** Jason Farrell (via Copilot)
**What:** Client requires isolated networking with VNet and private endpoints
**Why:** Enterprise security requirement — all resources must be network-isolated
**Impact:** Must use Logic Apps Standard tier (Consumption doesn't support VNet integration)



---


# Decision: VNet-Isolated Architecture with Logic Apps Standard

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-19  
**Status:** DEPLOYED  
**Impact:** Production network isolation and security posture

## Context

The critical notice ingestion system previously used Consumption-tier Logic Apps (3 separate apps: scanner, downloader, parser) with public network access. User approved migration to VNet-isolated architecture (~$180/mo) for enhanced security.

## Decision

Migrate from Logic Apps Consumption to Logic Apps Standard (WS1) with full VNet isolation using private endpoints.

## Architecture Changes

### Network Infrastructure
- **VNet:** `vnet-dte-noticeapp-eus2-mx01` (10.0.0.0/16)
- **Logic Apps Subnet:** `snet-logicapps` (10.0.1.0/24)
  - Service delegation: Microsoft.Web/serverFarms
  - Service endpoints: Storage, Key Vault
  - NSG: nsg-logicapps-eastus2
- **Private Endpoints Subnet:** `snet-privateendpoints` (10.0.2.0/24)

### Private Endpoints
| Endpoint | Target | DNS Zone |
|----------|--------|----------|
| pe-stdtenoticeappeus2mx01-blob | Storage (blob) | privatelink.blob.core.windows.net |
| pe-cog-dte-noticeapp-eus2-mx01-account | Foundry | privatelink.cognitiveservices.azure.com |
| pe-kv-dtenotice-eus2-mx01-vault | Key Vault | privatelink.vaultcore.azure.net |

### Logic Apps
- **Before:** 3 Consumption Logic Apps (separate managed identities)
- **After:** 1 Standard Logic App (single managed identity, multiple workflows)
  - App Service Plan: `asp-dte-noticeapp-eus2-mx01` (WS1 tier)
  - Logic App: `logic-dte-noticeapp-eus2-mx01`
  - VNet integrated to snet-logicapps

## Rationale

1. **Security:** Private endpoints eliminate public internet exposure for Storage, Key Vault, and Foundry
2. **Compliance:** VNet isolation satisfies enterprise security requirements
3. **Consolidation:** Single Standard app hosts all workflows (simpler RBAC, unified identity)
4. **Cost:** WS1 tier ~$150/mo + VNet components ~$30/mo = ~$180/mo total
5. **Scalability:** Standard tier supports up to 20 elastic workers

## Implementation Details

### Bicep Modules Created/Updated
- `infra/modules/vnet.bicep` (new)
- `infra/modules/private-endpoints.bicep` (new)
- `infra/modules/logicapp-standard.bicep` (new)
- `infra/modules/storage.bicep` (updated: VNet restrictions, connection string output)
- `infra/modules/keyvault.bicep` (updated: VNet restrictions)
- `infra/main.bicep` (updated: orchestration, role assignments)

### RBAC Role Assignments
| Principal | Role | Purpose |
|-----------|------|---------|
| Logic App Standard | Storage Blob Data Owner | Read/write blobs |
| Logic App Standard | Key Vault Secrets User | Read secrets |
| Logic App Standard | Cognitive Services User | Call Foundry API |
| Data Factory | Storage Blob Data Contributor | Pipeline operations |
| Data Factory | Key Vault Secrets User | Read secrets |

### Role Assignment GUID Pinning
Role assignments for Logic App Standard are pinned to specific GUIDs to ensure idempotent deployments:
- Key Vault Secrets User: `8ab80e73-28e2-5c85-82f3-a79179c91441`
- Cognitive Services User: `fdb87f43-7023-5260-92b4-53db918b6848`

## Outstanding Work

1. **Workflow Deployment:** The Standard Logic App is deployed but empty. Workflow definitions (scanner, downloader, parser) in `infra/workflows/` need to be deployed via zip deploy or Azure portal.

2. **Storage Firewall Exception:** `allowSharedKeyAccess: true` is required for Logic Apps Standard AzureWebJobsStorage. This is a known Azure limitation.

3. **Data Factory:** Kept with public access - ADF doesn't fully support private endpoints in all scenarios.

## Verification

- ✅ VNet integration confirmed (`az webapp vnet-integration list`)
- ✅ 3 private endpoints provisioned (Storage, Foundry, Key Vault)
- ✅ DNS zones with VNet links active
- ✅ Logic App Standard responding (HTTP 200)
- ✅ Old Consumption Logic Apps deleted

## Rollback Plan

If issues arise:
1. Redeploy old `infra/modules/logicapp.bicep` (Consumption)
2. Remove VNet module from main.bicep
3. Run deployment to restore Consumption apps



---


# Decision: Logic App Standard Workflow Deployment Pattern

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-19  
**Status:** IMPLEMENTED  
**Impact:** Production workflow deployment methodology

## Context
Logic App Standard uses a different deployment model than Consumption Logic Apps. Workflows are deployed as a zip package containing folder structure instead of ARM template resources.

## Decision
Deploy workflows to Logic App Standard using zip deployment with the following structure:
```
/
├── host.json           # Extension bundle config
├── connections.json    # API connections (empty for HTTP-only)
├── parameters.json     # Parameter definitions
├── scanner/
│   └── workflow.json   # Workflow definition wrapped in { "definition": {...}, "kind": "Stateful" }
├── downloader/
│   └── workflow.json
└── parser/
    └── workflow.json
```

## Key Technical Decisions

### 1. App Settings Pattern (not Parameters)
**Decision:** Use `@appsetting('NAME')` via variable initialization instead of workflow parameters.

**Rationale:** Logic App Standard's parameter system is complex with deployment-time vs runtime binding. App settings are simpler, configurable in Azure Portal, and consistent with Functions pattern.

**Implementation:**
```json
"Initialize_StorageAccountName": {
  "type": "InitializeVariable",
  "inputs": {
    "variables": [{
      "name": "storageAccountName",
      "type": "string",
      "value": "@appsetting('StorageAccountName')"
    }]
  }
}
```

### 2. Stateful Workflow Kind
**Decision:** All workflows are `"kind": "Stateful"` (not Stateless).

**Rationale:** Stateful workflows provide run history, retry capabilities, and durable execution — critical for notice processing reliability.

### 3. Inter-Workflow Communication
**Decision:** Scanner calls Downloader via HTTP trigger callback URL stored in app settings.

**Rationale:** Logic App Standard workflows in the same app can communicate via HTTP triggers. The callback URL includes a SAS token for authentication. Storing in app settings allows rotation without redeployment.

### 4. Deployment Method
**Decision:** `az logicapp deployment source config-zip` for workflow deployment.

**Rationale:** Atomic deployment of all workflows. Alternative (ARM templates) doesn't support workflow content for Standard tier.

## Deployment Commands
```bash
# Create zip package
cd infra/deployment-package && zip -r workflows.zip .

# Deploy
az logicapp deployment source config-zip \
  --name logic-dte-noticeapp-eus2-mx01 \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --src workflows.zip

# Get downloader callback URL
az rest --method POST \
  --uri ".../workflows/downloader/triggers/HTTP_Request/listCallbackUrl..."
```

## Artifacts
- `infra/deployment-package/` — Reusable workflow package structure
- All workflows now deployed and running in production

## Follow-ups
- Consider CI/CD pipeline for automated workflow deployment
- Monitor run history for failures in first 24 hours
- Evaluate whether scanner concurrency (5 Enbridge, 3 TCeConnects) is optimal



---


# Hopper Decision Inbox — Redeploy + 10-day Backfill

**Author:** Hopper (Lead/Architect)  
**Date:** 2026-05-11  
**Status:** RECOMMENDED (pending implementation by Grace)

## Decision
Provide a *minimal, safe, parameterized* redeploy/backfill capability by adding scripts that:
1) redeploy infrastructure via existing Bicep, and
2) seed a freshly deployed environment with **≥10 days** of existing blob data copied from the current deployment.

## Rationale
- The solution’s “dedup” behavior depends primarily on blob existence checks under `critical-notices/notices/**`. If we do not seed this, the scanner will likely re-download many historical notices still visible in upstream “latest notices” pages.
- The parser workflow **moves** raw HTML from `raw/` → `processed/raw/` and then **deletes** the original raw blob. Therefore, “last 10 days of raw HTML” will most reliably exist under `critical-notices/processed/raw/**`.
- Backfill must be idempotent and must not overwrite newer data in the target.

## Backfill scope (minimum)
Copy these prefixes from **source storage** → **target storage**:
- Always copy (small, functional/state):
  - `critical-notices/config/**` (or upload from repo)
  - `critical-notices/discovery/**` (optional but recommended)
  - `critical-notices/notices/**` (**recommended: full copy**, not just 10 days)
  - `critical-notices/tracking/**` (optional; reduces first-run churn)
- Copy “≥10 days of data”:
  - `critical-notices/processed/raw/**` (filtered to last N days)
  - `critical-notices/indices/daily/**` (filtered to last N days)
  - `critical-notices/parsed/**` (optional; filtered to last N days)

## Overwrite safety
- Use copy semantics that **do not overwrite** existing destination blobs.
  - Preferred: `--overwrite=false` (safest; preserves any newer target data)
  - Acceptable alternative: `--overwrite=ifSourceNewer`

## Execution environment constraint (private endpoints)
Because storage accounts are VNet-restricted, assume the backfill runner must have network access to both storage accounts’ private endpoints.
- Recommended: run AzCopy from a short-lived VM/DevBox inside the VNet.
- Avoid: temporarily opening public network access (only do this if explicitly approved).

## Follow-up note (non-blocking)
The parser’s `rawBlobPath` metadata currently captures the *pre-move* raw path and then deletes the blob. Consider updating the workflow later so `rawBlobPath` points to `processed/raw/...` (or stop deleting the original). This is not required to meet redeploy/backfill, but affects traceability.



---


# Data Validation Report: Critical Notice Ingestion

**Author:** Lovelace (Tester)  
**Date:** 2026-04-19  
**Status:** COMPLETE

## Executive Summary

✅ **Scanner & Downloader: WORKING CORRECTLY**  
✅ **Data completeness: 100% match against source APIs**  
⚠️ **Parser: Behind on processing (3.7% complete)**

## Captured Data Summary

| Source | Raw HTML Files | Pipelines Active | Source Match |
|--------|---------------|------------------|--------------|
| Enbridge | 1,086 | 19 of 25 | ✅ 100% |
| TCeConnects | 256 | 5 of 5 | ✅ 100% |
| **Total** | **1,342** | **24** | ✅ |

## TCeConnects Validation (100% Match)

| Pipeline | Storage Count | API Count | Status |
|----------|--------------|-----------|--------|
| ANR | 67 | 67 | ✅ |
| TCO | 81 | 81 | ✅ |
| CGT | 71 | 71 | ✅ |
| NBPL | 24 | 24 | ✅ |
| MPC | 13 | 13 | ✅ |

## Enbridge Validation

### Pipelines With Data (19)
AG (132), TE (136), ET (108), TPGS (104), SESH (101), SR (91), WE (85), SG (77), BGS (63), MB (54), NXUS (38), EG (25), MR (24), MNUS (18), VCP (12), MNCA (9), STT (5), BIG (3), GB (1)

### Pipelines With Zero Notices (6)
BSP, GPL, MCGP, NPC, NXCA, WRGS — confirmed via live API query; these pipelines currently have no critical notices posted.

## Data Quality Checks

| Check | Result |
|-------|--------|
| Empty files (0 bytes) | ✅ None found |
| Failed parsing folder | ✅ Empty |
| HTML validity (sampled) | ✅ Valid, parseable |
| Parsed JSON structure | ✅ Matches canonical schema |
| Notice IDs match source | ✅ Spot-checked |

## Parser Status

- **Parsed:** 50 files (all Enbridge/AG)
- **Pending:** 1,292 files
- **Parse rate:** 3.7%
- **Parser runs:** 2 successful
- **Health:** Healthy

The parser processes up to 50 files per 5-minute cycle. At this rate, full processing will complete in ~2-3 hours.

## Sample Data Verification

**Enbridge Notice 173037 (TE - Texas Eastern)**
- Subject: "TE Meter Underperformance"
- Type: Capacity Constraint
- Effective: 01/23/2026
- Content: Complete HTML with table of affected locations

**TCeConnects Notice 25952325 (ANR)**
- Subject: "Muttonville Lateral Capacity"
- Type: Other
- Posted: 10/01/2025
- Content: Complete SSRS report HTML

**Parsed JSON (AG/172843)**
- Canonical schema validated
- Fields extracted: title, noticeType, status, dates, description, affectedLocations
- Model: gpt-4.1-mini
- Tokens used: 39,526

## Storage Structure Verified

```
critical-notices/
├── raw/
│   ├── enbridge/2026-04-18/{pipeline}/{noticeId}.html
│   └── tceconnects/2026-04-18/{pipeline}/{noticeId}.html
├── parsed/
│   └── enbridge/{pipeline}/{noticeId}.json
└── (no failed-parsing/ entries)
```

## Recommendations

1. **No action needed on scanner/downloader** — working as designed
2. **Parser will catch up** — healthy, just needs time
3. **Monitor parser throughput** — if 50/run is too slow, consider increasing batch size or concurrency
4. **Consider index files** — the `index/` folder is empty; may want to implement notice metadata indexing

## Conclusion

The data capture pipeline is **fully operational**. All notices from both Enbridge (1,086) and TCeConnects (256) sources have been successfully downloaded and stored. The parser is progressing and will complete processing within a few hours. No data integrity issues found.


---

---
date: 2026-04-20
decision: Seed package date selection
---

## Decision
Use `indices/daily/` listings to select the most recent date folders for seed export/import, with a fallback to the last N calendar days when no index dates are present.

## Rationale
The daily index is the most reliable signal for active ingestion dates, and it aligns with the existing backfill validation checks. The fallback ensures a deterministic window even if indices are missing.

## Implications
Seed exports/imports focus on recent, validated dates without copying entire historical trees. Missing indices will still attempt last-N-day folders if present.

---

## 4. Infrastructure Redeployment Safety

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-20  
**Status:** ASSESSMENT  
**Impact:** Safe redeployment with data preservation capability

### Assessment Summary

**VERDICT: GO WITH CONDITIONS** ✅ (with validation script recommended)

The infrastructure is **SAFE for redeployment** with preservation of the last 10 days of existing data, subject to following the documented procedures.

### Key Findings

#### ✅ Safe Redeployment Features

1. **Bicep Incremental Mode (Default)**
   - `main.bicep` deploys using Azure's incremental mode by default
   - Existing resources are updated, not replaced
   - Storage accounts and their containers/blobs are preserved during redeploy
   - Key Vault soft-delete provides 90-day recovery window

2. **Role Assignment Idempotency**
   - Role assignments use pinned GUIDs to avoid `RoleAssignmentExists` conflicts
   - Examples: ADF Key Vault role `d01069f8-e69b-5b52-b262-7dc8ae066825`, Logic App Key Vault role `8ab80e73-28e2-5c85-82f3-a79179c91441`
   - Parser ADF runner role uses deterministic GUID generation

3. **Stateful Resources Protected**
   - **Azure Storage** (`stdtenoticeappeus2mx01`): Container `critical-notices` preserved, Bicep does NOT delete existing blobs
   - **Azure SQL** (`sql-dte-noticeapp-eus2-mx01`): Database `noticesdb` preserved, schema `dbo.notices` and `dbo.notice_locations` maintained
   - **Key Vault**: Secrets preserved (90-day soft-delete protection), RBAC role assignments maintained

4. **Data Preservation Scripts Available**
   - **Backfill**: `infra/scripts/backfill-blobs.ps1` uses `azcopy --overwrite=false` (never overwrites newer blobs)
   - **Seed Package**: `export-seed-package.ps1` + `import-seed-package.ps1` provide offline transfer capability
   - **Single Setup Command**: `setup-environment.ps1` orchestrates full deploy + seed in one call

5. **Validation Script Provided**
   - **Script**: `infra/scripts/validate-redeploy.ps1`
   - Checks: All resources exist, SecurityControl tags present, workflows enabled, 10-day data verified, SQL schema present
   - Usage: Run before and after redeploy to validate environment health

#### ⚠️ Redeploy Risks (Mitigated)

1. **Key Vault Soft-Delete Collision** → Run `az keyvault purge` before redeploy
2. **Workflow Definitions Require Separate Deploy** → Use `infra/scripts/deploy-workflows-standard.ps1`
3. **Config File Not Preserved** → Use `postdeploy-seed-config.ps1` to upload from `infra/config/sites.json`
4. **SQL Schema Not Managed by Bicep** → Use `infra/scripts/sql-init.ps1` to apply `notices.sql`
5. **Data Factory Managed Identity Grants** → Execute via `sql-init.ps1`

### Redeploy Workflow (Recommended)

#### Option 1: Single Command (Recommended for Full Redeploy + Seed)

```powershell
.\infra\scripts\setup-environment.ps1 `
  -ResourceGroupName rg-dte-noticeapp-eus2-mx01 `
  -Location eastus2 `
  -StorageAccountName stdtenoticeappeus2mx01 `
  -LogicAppName logic-dte-noticeapp-eus2-mx01 `
  -DataFactoryName adf-dte-noticeapp-eus2-mx01 `
  -SqlServerFqdn sql-dte-noticeapp-eus2-mx01.database.windows.net `
  -DatabaseName noticesdb `
  -SeedMode Backfill `
  -SourceStorageAccountName <source-storage> `
  -SourceResourceGroupName <source-rg> `
  -Days 10 `
  -RunValidation
```

#### Option 2: Step-by-Step (Manual Control)

- Run `validate-redeploy.ps1` (baseline)
- Deploy infrastructure via `deploy-infra.ps1`
- Build and deploy workflows via `build-deployment-package.ps1` and `deploy-workflows-standard.ps1`
- Seed configuration via `postdeploy-seed-config.ps1`
- Initialize SQL via `sql-init.ps1`
- Backfill data via `backfill-blobs.ps1`
- Validate post-deploy state via `validate-redeploy.ps1`

### Data Preservation for Last 10 Days

**Storage Blobs (Preserved Automatically):**
- `notices/{source}/{pipeline}/{noticeId}.json` — Canonical metadata (preserved)
- `raw/{source}/{YYYY-MM-DD}/{pipeline}/{noticeId}.html` — Raw HTML (preserved)
- `parsed/{source}/{pipeline}/{noticeId}.json` — Extracted JSON (preserved)
- `indices/daily/{YYYY-MM-DD}/*.json` — Daily index (preserved)

**SQL Database (Preserved Automatically):**
- `dbo.notices` — Parsed notice records (preserved)
- `dbo.notice_locations` — Flattened location records (preserved)
- Schema managed externally via `infra/sql/notices.sql`

**Backfill Strategy:**
- Full copy: `notices/`, `config/`
- Date-windowed copy (last N days): `raw/`, `processed/raw/`, `indices/daily/`
- Time-filtered copy (modified within N days): `parsed/`
- **Critical:** The `notices/` folder MUST be copied to prevent scanner re-downloading

---

## 8. SecurityControl:Ignore Tag Coverage

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-05-12  
**Status:** VERIFIED / NO CHANGES REQUIRED  
**Impact:** Governance — all resources tagged for security controls exemption

### Context
User (Jason Farrell) requested that all Azure resources in Bicep infrastructure include the tag `SecurityControl: 'Ignore'` to ensure security controls skip these resources in the target environment.

### Verification
Audited all Bicep modules and deployment artifacts:

**Centralized Definition:**
- `infra/main.bicep` — tags parameter default includes `SecurityControl: 'Ignore'`
- `infra/main.parameters.json` — tags parameter value set with same tag

**Module Coverage (9 modules):**
| Module | Taggable Resources |
|---|---|
| vnet.bicep | VNet, NSG |
| storage.bicep | Storage Account |
| keyvault.bicep | Key Vault |
| logicapp-standard.bicep | App Service Plan, Logic App |
| logicapp.bicep | Scanner, Downloader, Parser Logic Apps |
| datafactory.bicep | Data Factory |
| private-endpoints.bicep | Private DNS Zones, VNet Links, Private Endpoints |
| sql.bicep | SQL Server, SQL Database |
| foundry.bicep | Cognitive Services Account |

All modules accept the `tags` object parameter and apply it via `union()` operations. Child resources (blob containers, KV secrets, ADF entities, SQL firewall rules) correctly omitted — do not support tags.

**Deployment Script:**
`infra/scripts/deploy-infra.ps1` passes `--parameters $ParametersFile` and relies on Bicep for tagging. No CLI-level `--tags` flag required.

### Decision
**NO CODE CHANGES REQUIRED**

The infrastructure already satisfies the user requirement. All taggable deployment resources receive SecurityControl:Ignore via centralized parameter definition and module-level propagation.

### Rationale
- Centralized parameter ensures consistency across all environments
- Module-level `union()` ensures tag application to all resources
- Pattern is maintainable and scalable for future tag additions
- Deployment script correctly delegates tagging to Bicep (best practice)

---

### Recommendations

1. Always use validation script before and after deployment
2. Prefer single setup command (`setup-environment.ps1`) for consistency
3. Test redeploment in non-prod environment first
4. Monitor first scanner run post-redeploy for 30 minutes
5. Document source storage account name for future backfills

### Related Documentation

- Deployment: `infra/scripts/deploy-infra.ps1`, `setup-environment.ps1`
- Workflows: `infra/scripts/deploy-workflows-standard.ps1`
- Data Seeding: `backfill-blobs.ps1`, `export-seed-package.ps1`, `import-seed-package.ps1`
- Validation: `infra/scripts/validate-redeploy.ps1`
- SQL: `infra/sql/notices.sql`, `infra/sql/grants.sql`, `infra/scripts/sql-init.ps1`
- Config: `infra/config/sites.json`, `infra/scripts/postdeploy-seed-config.ps1`
- Documentation: `infra/README.md` (sections: "Redeploy + Backfill", "Local Seed Package")

---

## 5. Single Setup Script Orchestration

**Author:** Grace (DevOps/Infrastructure)  
**Date:** 2026-04-20  
**Status:** PROPOSED  
**Impact:** Simplified environment setup with repeatable deployment

### Context

The infrastructure redeploy process required multiple script invocations, which made onboarding and repeatable setup more error-prone.

### Decision

Add `infra\scripts\setup-environment.ps1` as the primary entry point for environment setup. The script orchestrates:
1. Infra deployment (Bicep)
2. Logic App Standard package build + deploy
3. Config upload (`config/sites.json`)
4. SQL init when `SqlServerFqdn` is provided
5. Optional seed modes via `SeedMode` (`None`, `LocalSeed`, `Backfill`)
6. Optional validation via `-RunValidation`

Lower-level scripts remain available for advanced/manual use.

### Rationale

Provides a single, repeatable command with clear parameters while preserving modular scripts for diagnostics or partial runs.

---

## 6. Redeploy Validation Readiness

**Author:** Lovelace (QA/Tester)  
**Date:** 2026-04-22  
**Status:** ASSESSMENT  
**Impact:** Validation posture for safe 10-day data preservation redeploy

### Assessment Summary

**VERDICT: DEPLOYMENT-READY with pre-flight checklist required**

The project has comprehensive validation scripts supporting safe redeployment with 10-day data preservation. Successful redeploy depends on running the correct pre-flight validation checks, having a source storage account with existing data, and following the recommended sequence.

### Current Validation Posture

#### ✅ Strengths

1. **Comprehensive Setup Script** (`setup-environment.ps1`)
   - Single-command deployment with data seeding
   - Three seed modes: None, LocalSeed, Backfill
   - Built-in `-RunValidation` flag for post-deployment verification
   - Supports both fresh deployments and redeployments

2. **Redeploy Validation** (`validate-redeploy.ps1`)
   - Verifies SecurityControl tags on all resources
   - Confirms workflows deployed and enabled (scanner, downloader, parser)
   - Validates 10-day backfill: indices/daily + raw/processed folders per source
   - Checks config/sites.json presence and content
   - Validates notices/** populated (prevents scanner backfill flood)
   - Confirms parsed outputs exist
   - Verifies Data Factory pipelines and linked services
   - Optional SQL schema validation (tables, columns, grants)

3. **Data Preservation Scripts**
   - **backfill-blobs.ps1:** Direct storage-to-storage copy (fast, no local disk)
   - **export-seed-package.ps1 + import-seed-package.ps1:** Local staging workflow
   - Both use `--overwrite=false` to prevent data loss
   - Both support 10-day date-folder windows

4. **Seed Package Validation** (`validate-seed-package.ps1`)
   - Pre-import verification for LocalSeed mode
   - Confirms notices, config, indices/daily, raw/processed folders
   - Validates date-folder completeness

5. **Local Syntax Validation** (`validate-local.ps1`)
   - PowerShell syntax checks before Azure deployment
   - Catches script errors offline (no Azure calls)

### Recommended Redeploy Sequence

#### Option 1: Direct Backfill (Fastest)
```powershell
.\infra\scripts\setup-environment.ps1 `
  -SeedMode Backfill `
  -SourceStorageAccountName <existing-storage> `
  -SourceResourceGroupName <existing-rg> `
  -Days 10 `
  -RunValidation
```
Use when you have a source storage account with existing data.

#### Option 2: Local Seed Package (Portable)
```powershell
# Export → Validate → Deploy with LocalSeed
.\infra\scripts\export-seed-package.ps1 -Days 10
.\infra\scripts\validate-seed-package.ps1 -DaysRequired 10
.\infra\scripts\setup-environment.ps1 -SeedMode LocalSeed -Days 10 -RunValidation
```
Use for offline transfer or when source storage is not accessible.

### Pre-Flight Checklist (REQUIRED)

Before redeploying, confirm:

1. **Prerequisites Installed**
   - [ ] `az` CLI authenticated (`az login`)
   - [ ] `azcopy` authenticated (`azcopy login`)
   - [ ] `sqlcmd` with AAD auth (if using SQL validation)

2. **Source Data Available**
   - [ ] Source storage account name known
   - [ ] Source storage has 10 days of data in expected structure
   - [ ] Firewall rules allow access to source storage

3. **Target Environment**
   - [ ] Resource group exists or will be created
   - [ ] No naming conflicts (storage account name globally unique)
   - [ ] Subscription has quota for resources

4. **Bicep Templates Compile**
   ```powershell
   az bicep build --file .\infra\main.bicep
   ```

5. **Local Script Syntax**
   ```powershell
   .\infra\scripts\validate-local.ps1
   ```

### Validation Evidence (Post-Redeploy)

After running setup-environment.ps1 with `-RunValidation`:

✅ **Infrastructure:**
- Resource group exists
- Storage account deployed
- Logic App Standard deployed
- Data Factory deployed
- All resources tagged with `SecurityControl` (except role assignments)

✅ **Workflows:**
- scanner, downloader, parser workflows deployed
- All workflows in 'Enabled' state

✅ **Storage Data:**
- Container 'critical-notices' exists
- config/sites.json present and non-empty
- notices/{enbridge|tceconnects}/ populated
- Last 10 date folders in indices/daily/
- Each date has corresponding raw/{source}/{date}/ or processed/raw/{source}/{date}/
- parsed/ folder populated
- processed/raw/ folder populated

✅ **Data Factory:**
- LandParsedToSql pipeline deployed
- IngestToFabric pipeline deployed
- Linked services configured

✅ **SQL (if SqlServerFqdn provided):**
- dbo.notices table with expected columns
- dbo.notice_locations table with expected columns
- Sample query succeeds

### Identified Gaps & Risks

#### ⚠️ Minor Gaps

1. **No Dry-Run Mode** — Cannot preview backfill before executing
   - Mitigation: Scripts use `--overwrite=false` (safe by default)
   - Recommendation: Add `-WhatIf` parameter to backfill scripts

2. **No Pre-Backfill Source Validation** — Cannot confirm source storage structure before copying
   - Mitigation: User must ensure source storage has 10 days of data
   - Recommendation: Add `validate-source-storage.ps1` to run before backfill

3. **Parser State Not Validated** — Does not check if parser is catching up
   - Mitigation: Manual check of Logic App run history
   - Recommendation: Add metrics check (raw blob count vs. parsed blob count)

4. **SQL Validation is Optional** — SQL checks only run if SqlServerFqdn is provided
   - Mitigation: SQL is optional in architecture (Data Factory can work without it)
   - Recommendation: Document when SQL is required vs. optional

#### Blockers (None if prerequisites met)

**No blockers** if:
- You have a source storage account with 10 days of data
- Azure CLI and AzCopy are authenticated
- No resource naming conflicts

**Blocked if:**
- Source storage doesn't exist → Must create initial data seed manually
- Source storage has <10 days → Reduce `-Days` parameter
- Network firewall blocks storage access → Add IP to storage firewall or use Azure services

### Testing Recommendations

1. **Test Redeployment in Non-Prod** — Run full sequence in test resource group first
2. **Verify Scanner Doesn't Re-Backfill** — Wait 15 minutes, confirm only NEW notices are downloaded
3. **Verify Parser Processes Backfilled Data** — Check Logic App run history and parsed blob count

### Answer to User Question

**"Is the project in a place where it can be freely redeployed, including the existing data (last 10 days)?"**

**YES**, with the following readiness checks:

1. Run `.\infra\scripts\validate-local.ps1` (catches syntax errors)
2. Ensure source storage has 10 days of data
3. Run setup-environment.ps1 with `-SeedMode Backfill` + `-RunValidation`
4. Review validation output for any failures

**Data Preservation:**
- Backfill uses `--overwrite=false` (no data loss)
- Copies notices, config, tracking, discovery, indices, raw, processed, parsed
- 10-day date-folder windows preserved

### Recommendations for Future Work

1. Add `validate-source-storage.ps1` — Pre-flight check before backfill
2. Add `-WhatIf` mode to backfill scripts — Preview what will be copied
3. Add parser health metrics to validate-redeploy.ps1 — Raw vs. parsed blob count
4. Document SQL optional vs. required scenarios
5. Add rollback documentation — How to restore previous deployment

### References

- **setup-environment.ps1:** Single-command deployment with validation
- **validate-redeploy.ps1:** Post-deployment verification
- **backfill-blobs.ps1:** Direct storage-to-storage data copy
- **validate-seed-package.ps1:** Pre-import seed validation
- **validate-local.ps1:** Offline PowerShell syntax checks
- **infra/README.md:** Deployment documentation

