# Grace — History

## Core Context

Project: Critical notice ingestion infrastructure for Enbridge Infopost sites.
Stack: Azure Logic Apps, Blob Storage, Key Vault, Data Factory, Bicep IaC.
User: Jason Farrell

## Learnings

- 2026-04-17: Project initiated. Infrastructure scope: Logic Apps Standard (WS1), Blob Storage (hot tier), Key Vault, Data Factory. Resource group: rg-dte-noticeapp-eus2-mx01, East US 2. Storage account name confirmed: stdtenoticeappeus2mx01. Fabric is out of scope — handled by separate team.

- 2026-04-17: Created complete Bicep infrastructure. Modular design with 4 modules (storage, keyvault, logicapp, datafactory). Key design decisions:
  - RBAC authorization for Key Vault (not access policies) — modern best practice
  - System-assigned managed identities on Logic Apps and Data Factory
  - Storage Blob Data Contributor and Key Vault Secrets User roles auto-assigned
  - Lifecycle policy: Hot → Cool (30d) → Archive (90d)
  - Logic Apps uses same storage account for internal state (AzureWebJobsStorage)
  - All resources follow Azure naming convention: {type}-dte-noticeapp-eus2-mx01

- 2026-04-18: Implemented Parser Logic App with Microsoft Foundry integration:
  - Created `infra/modules/foundry.bicep` — Cognitive Services (OpenAI) account with GPT-4o-mini deployment
  - Created `infra/workflows/parser-multisite.json` — Logic App workflow for HTML → JSON parsing
  - Updated `infra/main.bicep` to deploy Foundry module and wire up Parser Logic App
  - Updated `infra/modules/logicapp.bicep` to add Parser Logic App resource
  - Updated `infra/modules/keyvault.bicep` to store Foundry API key
  - Design patterns:
    - Recurrence trigger (5-minute polling) instead of blob trigger for simplicity
    - XML parsing of Azure Blob Storage list API response
    - Foreach loop to process up to 50 raw HTML blobs per run
    - Idempotency check: HEAD request to parsed/ path before processing
    - Error handling: failed items logged to `failed-parsing/` folder
    - Output structure: `parsed/{source}/{pipeline}/{noticeId}.json` with metadata + extracted fields
    - Foundry called via v2 API endpoint (Azure OpenAI compatible)
    - JSON mode enforced via `response_format: json_object`
    - Low temperature (0.1) for deterministic extraction
  - RBAC: Parser Logic App granted Storage Blob Data Contributor role
  - No API connections required — direct HTTP + managed identity for all storage operations

- 2026-04-18: Deployed full infra (Foundry + Parser) to `rg-dte-noticeapp-eus2-mx01`:
  - Foundry: `gpt-4o-mini` deployment was blocked by `ServiceModelDeprecated` in this subscription/region, so deployment was switched to `gpt-4.1-mini` (`2025-04-14`).
  - Parser workflow updated to default to `gpt-4.1-mini`.
  - Fixed redeploy collision: existing ADF `Key Vault Secrets User` role assignment had a non-standard GUID, so `infra/main.bicep` pins to the existing roleAssignment ID to avoid `RoleAssignmentExists` failures.
  - Verified Foundry endpoint returns HTTP 200 for `chat/completions`; Parser Logic App is enabled and has successful runs.

- 2026-04-18: Migrated Foundry from deprecated `kind: OpenAI` to `kind: AIServices` (Cognitive Services v2):
  - Account endpoint changed from `*.openai.azure.com` to `*.cognitiveservices.azure.com`.
  - Deployed `gpt-5.2` (`2025-12-11`) successfully.
  - `GlobalStandard` SKU was blocked by quota in East US 2; used `DataZoneStandard` with capacity 1 to fit available quota.
  - Deleting the old account required a follow-up purge due to soft-delete before redeploy could succeed.
  - Parser workflow default updated to `gpt-5.2` (deployment name remains parameterized).

- 2026-04-19: Implemented VNet-isolated architecture with Logic Apps Standard (~$180/mo):
  - Created `infra/modules/vnet.bicep` — VNet (10.0.0.0/16) with two subnets:
    - `snet-logicapps` (10.0.1.0/24): Service delegation for Web/serverFarms, service endpoints for Storage + Key Vault
    - `snet-privateendpoints` (10.0.2.0/24): For private endpoints
    - NSG with rules for Azure Cloud, Internet outbound, Logic Apps management inbound
  - Created `infra/modules/private-endpoints.bicep` — Private endpoints for:
    - Storage Account (blob): `pe-stdtenoticeappeus2mx01-blob`
    - Foundry (Cognitive Services): `pe-cog-dte-noticeapp-eus2-mx01-account`
    - Key Vault: `pe-kv-dtenotice-eus2-mx01-vault`
    - Private DNS zones with VNet links for DNS resolution
  - Created `infra/modules/logicapp-standard.bicep` — Logic Apps Standard (WS1):
    - App Service Plan: `asp-dte-noticeapp-eus2-mx01` (WorkflowStandard WS1)
    - Logic App: `logic-dte-noticeapp-eus2-mx01` (single app, multiple workflows)
    - VNet integration to `snet-logicapps` subnet
    - System-assigned managed identity with RBAC roles
    - App settings for Storage, Foundry, Key Vault connections
  - Updated `infra/modules/storage.bicep`:
    - Added VNet restrictions (allowSharedKeyAccess: true for AzureWebJobsStorage)
    - Service endpoint ACLs for Logic Apps subnet
    - Output connection string for Logic Apps Standard
  - Updated `infra/modules/keyvault.bicep`:
    - Added VNet restrictions (publicNetworkAccess: Disabled when enabled)
    - Service endpoint ACLs for Logic Apps subnet
  - Updated `infra/main.bicep`:
    - VNet module deployed first (foundation)
    - Private endpoints after VNet, Storage, Foundry, Key Vault
    - Replaced Consumption Logic Apps module with Standard
    - New role assignments with pinned GUIDs for idempotency
  - Deleted old Consumption Logic Apps:
    - `logic-dte-noticeapp-eus2-mx01-scanner`
    - `logic-dte-noticeapp-eus2-mx01-downloader`
    - `logic-dte-noticeapp-eus2-mx01-parser`
  - Verified: VNet integration active, private endpoints provisioned, Logic App responding HTTP 200
  - Note: Workflow definitions (scanner, downloader, parser) to be deployed separately via zip deploy

- 2026-04-19: Deployed workflow definitions to Logic App Standard (`logic-dte-noticeapp-eus2-mx01`):
  - Created `infra/deployment-package/` with Logic App Standard folder structure:
    - `host.json` — Extension bundle config for workflow runtime
    - `connections.json` — Empty (no managed API connections needed)
    - `parameters.json` — References to app settings via `@appsetting()`
    - `scanner/workflow.json` — Adapted from Consumption format
    - `downloader/workflow.json` — HTTP-triggered workflow for notice download
    - `parser/workflow.json` — Recurrence-triggered Foundry GPT-5.2 parser
  - Key adaptations from Consumption to Standard format:
    - Wrapped workflow definitions in `{ "definition": {...}, "kind": "Stateful" }`
    - Replaced `@parameters('...')` with `@appsetting('...')` pattern using variable initialization
    - Variables read app settings at workflow start, then used throughout actions
    - Scanner calls downloader via `DOWNLOADER_CALLBACK_URL` app setting
  - Configured app settings:
    - `FoundryApiKey` — API key from Cognitive Services account
    - `DOWNLOADER_CALLBACK_URL` — Callback URL with SAS token for downloader HTTP trigger
  - Deployed via `az logicapp deployment source config-zip`
  - Verified all 3 workflows present and running:
    - scanner: Running (scans Enbridge + TCeConnects every 15 min)
    - downloader: Enabled (HTTP trigger, called by scanner)
    - parser: Succeeded (polls raw/ folder every 5 min, parses with GPT-5.2)

- 2026-04-19: Added redeploy/backfill automation under `infra/scripts`:
  - `deploy-infra.ps1`, `build-deployment-package.ps1`, `deploy-workflows-standard.ps1`
  - `postdeploy-seed-config.ps1` to upload `config/sites.json` safely
  - `sql-init.ps1` to apply `notices.sql` + grants with AAD auth
  - `backfill-blobs.ps1` uses AzCopy (`--overwrite=false`) and time-window copy for raw/indices/parsed
  - Updated `infra/README.md` with end-to-end redeploy + backfill sequence

- 2026-04-20: Added local seed package workflow scripts for offline export/import:
  - `export-seed-package.ps1` and `import-seed-package.ps1` stage `notices/`, `config/`, optional `tracking/` + `discovery/`, recent index/raw/processed folders, and recent `parsed/` blobs.
  - Default seed path is `infra\seed-package` (gitignored); import is non-overwrite by default.

- 2026-04-20: Added one-command setup script `infra\scripts\setup-environment.ps1` orchestrating infra deploy, workflow package build/deploy, config upload, SQL init (when provided), and optional seed modes (`None`, `LocalSeed`, `Backfill`). Parameters include resource names, SQL target, seed path/source, days (default 10), subscription, and optional validation.

- 2026-04-20: **Redeploy Safety Assessment**: Project is SAFE for redeployment with data preservation. Key findings:
  - Bicep uses incremental mode (default) — stateful resources preserved
  - Storage account and `critical-notices` container persisted during redeploy
  - SQL database and schema preserved (AAD-only auth maintained)
  - Role assignments use pinned GUIDs to avoid conflicts on redeploy
  - Backfill scripts use `--overwrite=false` to protect newer data
  - Validation script (`validate-redeploy.ps1`) checks environment health before/after
  - Critical: `notices/` folder must be copied during backfill to prevent scanner from re-downloading all existing notices
  - Documented single-command redeploy via `setup-environment.ps1` with `-SeedMode Backfill -Days 10`
  - Step-by-step manual redeploy sequence also documented
  - Key risks mitigated: Key Vault soft-delete collision, workflow definitions require separate deploy, config file must be reseeded, SQL schema managed externally
  - Decision document: `.squad/decisions/inbox/grace-redeploy-safety.md`

- 2026-05-12: **Orchestration Log Created**: Documented Grace's redeploy safety assessment in .squad/orchestration-log/2026-05-12T18-29-30Z-grace.md with assessment verdict (GO WITH CONDITIONS), key deliverables, findings, and recommendations. Merged decision documents into main decisions.md. Assessment remains current and ready for execution.

- 2026-05-12: **SecurityControl: Ignore tag audit** — Verified that `SecurityControl: 'Ignore'` is already correctly propagated across the entire infrastructure. Tag is defined centrally in `main.bicep` (tags param default) and also explicitly set in `main.parameters.json`. All 9 modules (storage, keyvault, logicapp-standard, logicapp, datafactory, vnet, private-endpoints, sql, foundry) accept a `tags object` param and apply it via `tags: tags` or `union(tags, { ... })` on every taggable top-level resource. Child resources (blob containers, KV secrets, ADF linked services, SQL firewall rules, DNS zone groups) do not support tags in ARM and are correctly omitted. `deploy-infra.ps1` passes `--parameters $ParametersFile` only — no `--tags` flag at CLI level — so no script change was needed. Pattern: define once in main, pass through every module, use `union()` when a module adds its own supplemental tags. Decision document: `.squad/decisions/inbox/grace-security-tag.md`.

- 2026-05-12: **Test1 deployment blockers patched for recovery**: Fixed 4 critical blockers preventing test1-suffixed environment redeploys:
  1. **Role assignment name collision**: Static GUIDs `8ab80e73-28e2-5c85-82f3-a79179c91441`, `fdb87f43-7023-5260-92b4-53db918b6848`, `d01069f8-e69b-5b52-b262-7dc8ae066825` are now pinned ONLY for `environment == 'prod'`. Non-prod uses deterministic `guid(resourceGroup().id, ...)` scoped to the RG + resource/principal to avoid collisions across test environments.
  2. **Storage network firewall**: Added `-AllowCallerIp` switch to `setup-environment.ps1`. When enabled, detects public IP via ipify.org, adds temporary IP rules to target storage (and source storage when backfilling), waits 15s for propagation, then removes rules in `finally` block for guaranteed cleanup. Safe default: opt-in only.
  3. **SQL init auth failure**: Added `-SkipSqlInit` switch to `setup-environment.ps1`. Prevents hard failure when Windows/tenant AAD context doesn't match SQL tenant. Coordinator can rerun with `-SkipSqlInit` and handle SQL separately.
  4. **Backfill source storage RBAC/firewall**: Handled by `-AllowCallerIp` — automatically adds IP rule to source storage when `SeedMode = 'Backfill'` and `SourceResourceGroupName` is supplied, with cleanup.
  Decision document: `.squad/decisions/inbox/grace-test1-deployment-blockers.md`.

