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
