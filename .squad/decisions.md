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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
