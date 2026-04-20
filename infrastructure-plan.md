# Critical Notice Extraction Engine - Infrastructure Plan

## Executive Summary

This document outlines a **low-code/no-code solution** using Azure Logic Apps to extract critical notices from **multiple pipeline operator websites** and store them in Microsoft Fabric. The architecture supports both HTML scraping (Enbridge) and JSON API (TCeConnects) sources with a unified storage schema.

---

## Data Sources

### Source 1: Enbridge Infopost (HTML Scraping)

**Site Type:** Class 1 - HTML table scraping with regex extraction

**Business Units (25 total):**
| Abbreviation | Name |
|--------------|------|
| AG | Algonquin Gas Transmission, LLC |
| BGS | Bobcat Gas Storage |
| BIG | BIG Pipeline |
| BSP | Big Sandy Pipeline |
| EG | MHP Egan (EHP) |
| ET | East Tennessee (ETNG) |
| GB | Garden Banks |
| GPL | Generation Pipeline |
| MCGP | Mississippi Canyon |
| MB | MHP Moss Bluff (MBHP) |
| MNCA | Maritimes & Northeast Canada |
| MNUS | Maritimes & Northeast U.S. |
| MR | Manta Ray Offshore Gathering Company |
| NPC | Nautilus Pipeline Company |
| NXCA | NEXUS ULC |
| NXUS | NEXUS U.S. |
| SESH | Southeast Supply Header |
| SG | Saltville (SGSC) |
| SR | Steckman Ridge |
| STT | Sabal Trail |
| TE | Texas Eastern |
| TPGS | Tres Palacios Gas Storage LLC |
| VCP | Valley Crossing Pipeline |
| WE | Westcoast Energy |
| WRGS | Walker Ridge Gathering System |

**URL Patterns:**
```
List:   https://infopost.enbridge.com/infopost/noticesList.asp?pipe={CODE}&type=CRI
Detail: https://infopost.enbridge.com/infopost/NoticeListDetail.asp?strKey1={ID}&type=CRI&Embed=2&pipe={CODE}
```

### Source 2: TC Energy Connects (JSON API)

**Site Type:** Class 2 - JSON API with SSRS detail pages

**Business Units (5 total):**
| Code | Asset ID | Name |
|------|----------|------|
| ANR | 3005 | ANR Pipeline Company |
| TCO | 51 | Columbia Gas Transmission |
| CGT | 14 | Columbia Gulf Transmission |
| MPC | 26 | Midwestern Gas Transmission |
| NBPL | 3029 | Northern Border Pipeline |

**URL Patterns:**
```
List:   https://www.tceconnects.com/infopost/webmethods/SSRS_ListCriticalNotices.aspx?assetid={ASSET_ID}&page=1&rows=100
Detail: https://www.tceconnects.com/infopost/ReportViewer.aspx?%2fInfoPost%2fNoticesSubreport&pNoticeId={ID}&AssetNbr={ASSET_ID}&rs:Format=HTML4.0
```

**JSON Response Format:**
```json
{
  "total": 10,
  "page": 1,
  "records": 100,
  "rows": [
    {"id": "25991612", "cell": ["25991612", "Notice Title", "04/17/2026"]}
  ]
}
```

---

## Unified Data Model

### Canonical Notice Schema (Fabric-Ready)

Both sources map to this unified schema for downstream processing:

| Field | Type | Description |
|-------|------|-------------|
| source | STRING | Site identifier: `enbridge` \| `tceconnects` |
| pipeline | STRING | Business unit code (e.g., TE, ANR) |
| pipelineName | STRING | Full pipeline company name |
| noticeId | STRING | Unique notice identifier |
| noticeType | STRING | Notice type (Maintenance, Capacity Constraint, etc.) |
| status | STRING | Notice status (Initiate, Supersede, Cancel) |
| isCritical | BOOLEAN | Critical notice flag |
| title | STRING | Notice subject/title |
| postedDate | DATETIME | When notice was posted |
| effectiveDate | DATETIME | When notice takes effect |
| endDate | DATETIME | When notice expires |
| responseRequired | BOOLEAN | Whether response is required |
| sourceUrl | STRING | Original URL for the notice |
| rawBlobPath | STRING | Path to raw HTML in storage |
| scrapedAt | DATETIME | When we captured this notice |

---

## Infrastructure Components

### 1. Azure Logic Apps (Standard Plan) - **Primary Orchestration**

**Why Logic Apps:**
- Visual designer - no code required
- Built-in HTTP connectors for web scraping
- Native JSON parsing for API responses
- Native Azure Blob Storage connector
- Native Data Factory integration
- Scheduled triggers (recurrence)
- Retry policies built-in

**Logic App Workflows:**

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| `scanner-multisite` | Reads site registry from blob, dispatches each enabled site by `parserModel` (Switch) | Scheduled (every 15 min) |
| `downloader-multisite` | Downloads individual notices from any source | HTTP trigger (called by Scanner) |

**Registry-driven dispatch:** the scanner has no source-specific scopes. It loads `critical-notices/config/sites.json` at runtime and routes each site to a Switch case keyed on `parserModel`. Current models:

| parserModel | List shape | Used by |
|---|---|---|
| `html-table-v1` | HTML `<tr>` rows; noticeId via query-string token | Enbridge (25 BUs) |
| `json-grid-v1` | JSON `{ rows: [{ id, cell: [noticeId, title, postedDate] }] }` | TC Energy Connects (5 BUs) |

To add a new source that fits an existing model, only the registry blob changes (no redeploy). New models require a new Switch case in `scanner-multisite.json`.

### 2. Azure Blob Storage - **Unified Data Lake**

**Storage Account:** `stdtenoticeappeus2mx01`

**Container Structure (Multi-Site):**
```
critical-notices/
├── notices/                           # Canonical notice metadata (JSON)
│   ├── enbridge/
│   │   └── {pipeline}/{noticeId}.json
│   └── tceconnects/
│       └── {pipeline}/{noticeId}.json
├── raw/                               # Raw HTML content
│   ├── enbridge/
│   │   └── {YYYY-MM-DD}/{pipeline}/{noticeId}.html
│   └── tceconnects/
│       └── {YYYY-MM-DD}/{pipeline}/{noticeId}.html
├── tracking/                          # Change detection state
│   ├── enbridge/{pipeline}.json       # Last-seen notice per unit
│   ├── tceconnects/{pipeline}.json
│   └── scan-summary.json              # Overall scan status
├── indices/                           # Daily indexes for reporting
│   └── daily/{YYYY-MM-DD}/*.json      # All notices captured that day
└── config/
    └── sites.json                     # Multi-site configuration
```

**Deduplication Strategy:**
- Before downloading, check if `notices/{source}/{pipeline}/{noticeId}.json` exists
- Uses HTTP HEAD request (cheap, no data transfer)
- Only downloads NEW notices not already in storage
- Tracking files record last-seen state per pipeline

**Storage Tier:** Hot (frequent access during polling)
**Lifecycle Policy:** Move to Cool after 30 days, Archive after 90 days

### 3. Microsoft Fabric - **Target Data Platform**

**Lakehouse Structure:**
```
CriticalNotices_Lakehouse/
├── Tables/
│   ├── raw_notices           # All downloaded notices (unified schema)
│   ├── sources               # Source site reference table
│   ├── pipelines             # Pipeline/business unit reference
│   └── change_log            # Audit trail of new notices
└── Files/
    └── raw_archive/          # Shortcut to Blob Storage raw content
```

**Key Tables:**

**`raw_notices`:**
| Column | Type | Description |
|--------|------|-------------|
| source | STRING | enbridge \| tceconnects |
| pipeline | STRING | Business unit code |
| pipeline_name | STRING | Full company name |
| notice_id | STRING | Unique identifier (PK with source+pipeline) |
| notice_type | STRING | Capacity Constraint, Maintenance, etc. |
| posted_datetime | TIMESTAMP | When posted |
| effective_datetime | TIMESTAMP | When notice takes effect |
| end_datetime | TIMESTAMP | When notice expires |
| title | STRING | Notice subject line |
| raw_blob_path | STRING | Path to raw HTML in storage |
| scraped_at | TIMESTAMP | When we captured it |

### 4. Azure Key Vault - **Secrets Management**

Store:
- Storage account connection strings
- Fabric workspace credentials
- Any API keys if needed

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              AZURE LOGIC APPS                                        │
│  ┌───────────────────┐    ┌─────────────────────────────────────────────────────┐   │
│  │  Recurrence       │───▶│  scanner-multisite                                   │   │
│  │  (Every 15 min)   │    │                                                      │   │
│  └───────────────────┘    │  ┌─────────────────┐    ┌─────────────────┐         │   │
│                           │  │ SCOPE: Enbridge │    │ SCOPE: TCeConn. │         │   │
│                           │  │ (25 units)      │    │ (5 units)       │         │   │
│                           │  │ HTML scraping   │    │ JSON API        │         │   │
│                           │  └────────┬────────┘    └────────┬────────┘         │   │
│                           └───────────┼──────────────────────┼──────────────────┘   │
│                                       │                      │                       │
│                           ┌───────────▼──────────────────────▼───────────┐          │
│                           │  Check: notices/{source}/{pipeline}/{id}.json │          │
│                           │  exists? (HTTP HEAD - deduplication)          │          │
│                           └───────────┬───────────────────────────────────┘          │
│                                       │ (if 404 = new notice)                        │
│                           ┌───────────▼───────────────────────────────────┐          │
│                           │  downloader-multisite                          │          │
│                           │  • Downloads raw HTML                          │          │
│                           │  • Creates canonical JSON metadata             │          │
│                           │  • Updates daily index                         │          │
│                           └───────────┬───────────────────────────────────┘          │
└───────────────────────────────────────┼──────────────────────────────────────────────┘
                                        │
                        ┌───────────────┼───────────────┐
                        │               │               │
                        ▼               ▼               ▼
            ┌──────────────────┐ ┌──────────────┐ ┌──────────────────┐
            │  Azure Blob      │ │  Microsoft   │ │  Azure Key       │
            │  Storage         │ │  Fabric      │ │  Vault           │
            │  (Unified Lake)  │ │  (Lakehouse) │ │  (Secrets)       │
            └──────────────────┘ └──────────────┘ └──────────────────┘
```

---

## Change Detection & Deduplication

### Strategy: "Check Before Download"

The scanner uses a simple but effective deduplication strategy:

1. **Fetch notice list** from source (HTML for Enbridge, JSON for TCeConnects)
2. **Extract notice IDs** from the list
3. **For each notice ID**, issue an HTTP HEAD request to check if it exists:
   ```
   HEAD /critical-notices/notices/{source}/{pipeline}/{noticeId}.json
   ```
4. **If 404** (not found) → Call downloader to fetch and store
5. **If 200** (exists) → Skip, already captured

**Benefits:**
- No separate "last-seen" tracking database needed
- Idempotent - safe to re-run at any time
- Self-healing - if notice metadata is missing, it will be re-downloaded
- Works across restarts - state is in blob storage

### Tracking Files (Observability)

For monitoring and debugging, tracking files are updated after each scan:

**`tracking/{source}/{pipeline}.json`:**
```json
{
  "source": "enbridge",
  "pipeline": "TE",
  "lastChecked": "2026-04-18T15:30:00Z",
  "lastSeenNoticeId": "176751",
  "noticesInWindow": 12
}
```

**`tracking/scan-summary.json`:**
```json
{
  "lastScanCompleted": "2026-04-18T15:30:00Z",
  "backfillWindowDays": 10,
  "sitesScanned": ["enbridge", "tceconnects"],
  "enbridgeUnits": 25,
  "tceconnectsUnits": 5
}
```

---

## Daily Index (Last 10 Days Listing)

The `indices/daily/{date}/` folder accumulates all notices captured each day:

```
indices/daily/2026-04-18/
├── enbridge-TE-176751.json
├── enbridge-AG-176752.json
├── tceconnects-ANR-25991612.json
└── ...
```

**Query all notices from last 10 days:**
1. List blobs with prefix: `indices/daily/`
2. Filter by date folders within range
3. Each file is a lightweight index entry with key metadata

This enables efficient "what's new" queries without scanning all notices.

---

## Site Type Abstraction

**Configuration file:** `infra/config/sites.json`

New sources can be added by:
1. Adding a new entry to `sites.json` with URL patterns and unit list
2. Creating a new SCOPE block in the scanner workflow
3. The downloader is source-agnostic (works with any source)

---

## Cost Projection

### Monthly Cost Estimate (15-Minute Polling, 30 Pipelines Total)

| Component | SKU/Tier | Est. Monthly Cost |
|-----------|----------|-------------------|
| **Logic Apps (Standard)** | WS1 (1 vCPU, 3.5GB) | ~$174 |
| **Azure Blob Storage** | Hot tier, 15GB data | ~$3 |
| **Azure Key Vault** | Standard, <1000 ops/mo | ~$0.03 |
| **Microsoft Fabric** | Existing workspace (colleague) | $0 (shared) |
| **Networking** | Outbound data <15GB | ~$1.50 |
| | | |
| **Total** | | **~$179/month** |

---

## Implementation Phases

### Phase 1: Core Multi-Site Pipeline (Week 1-2)
- [x] Site analysis and API discovery
- [x] Design unified storage schema
- [x] Create multi-site scanner workflow
- [x] Create multi-site downloader workflow
- [ ] Provision Azure resources
- [ ] Deploy and test with single unit per source
- [ ] Manual validation

### Phase 2: Full Deployment & Monitoring (Week 3)
- [ ] Enable all 30 pipelines (25 Enbridge + 5 TCeConnects)
- [ ] Set up tracking and daily index
- [ ] Connect to Microsoft Fabric Lakehouse
- [ ] Build reference tables in Fabric
- [ ] Set up alerting on failures

### Phase 3: Enrichment & Extensibility (Week 4)
- [ ] Add HTML parsing for structured field extraction
- [ ] Consider Azure Document Intelligence for complex notices
- [ ] Document process for adding new sources
- [ ] User training materials

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Site structure changes | Data extraction breaks | Config-based parsing, store raw HTML |
| Rate limiting by sources | Blocked requests | Throttle polling, add delays, concurrent limits |
| HTML parsing fragility | Missing data | Store raw HTML, parse later with AI |
| Fabric connectivity issues | Data not landing | Retry policies in Logic Apps |
| TCeConnects JSON format changes | List parsing fails | Schema validation, fallback to SSRS |

---

## Decisions Made

| Decision | Value | Notes |
|----------|-------|-------|
| **Polling frequency** | 15 minutes | Balance of timeliness vs. cost |
| **Storage account name** | `stdtenoticeappeus2mx01` | Confirmed |
| **Fabric workspace** | Existing | Created by colleague |
| **Backfill window** | 10 days | Configurable via parameter |
| **Deduplication** | Check-before-download | HTTP HEAD to blob storage |
| **TCeConnects approach** | JSON API (no Playwright) | Discovered clean API endpoint |
| **Alerting** | Out of scope | Handled by Fabric team separately |

## Scope Clarification

**This system handles INGESTION ONLY:**
- ✅ Poll Enbridge Infopost for new critical notices (HTML scraping)
- ✅ Poll TC Energy Connects for new critical notices (JSON API)
- ✅ Detect new notices via blob existence check (deduplication)
- ✅ Download and store raw HTML to Blob Storage
- ✅ Create canonical JSON metadata per notice
- ✅ Maintain daily index for last-10-days queries
- ✅ Write tracking state for observability

**Out of scope (handled by Fabric team):**
- ❌ Alerting and notifications
- ❌ Dashboards and reporting
- ❌ Data transformation beyond basic metadata extraction
- ❌ HTML parsing for structured field extraction (Phase 3)

---

## Files Created/Updated

| File | Purpose |
|------|---------|
| `infra/config/sites.json` | Multi-site configuration with all pipelines |
| `infra/workflows/scanner-multisite.json` | Unified scanner for both sources |
| `infra/workflows/downloader-multisite.json` | Source-agnostic notice downloader |
| `infra/modules/storage.bicep` | Updated storage with new container structure |
| `infrastructure-plan.md` | This document |

---

## Next Steps

1. ⏳ Provision Azure resources with updated Bicep
2. ⏳ Deploy scanner-multisite and downloader-multisite workflows
3. ⏳ Test with single pipeline from each source (TE, ANR)
4. ⏳ Validate storage structure and deduplication
5. ⏳ Enable all 30 pipelines
6. ⏳ Connect to Fabric and validate end-to-end
