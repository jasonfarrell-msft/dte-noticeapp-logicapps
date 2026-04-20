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
│   │  Recurrence       │───▶│  scanner-multisite (registry-driven, v4)     │  │
│   │  (Every 15 min)   │    │                                              │  │
│   └───────────────────┘    │  1. Read site registry from blob             │  │
│                            │  2. Per site: GET rootUrl                    │  │
│                            │  3. Discover BUs (inline JS)                 │  │
│                            │  4. Switch on parserModel:                   │  │
│                            │       html-table-v1 │ json-grid-v1          │  │
│                            └──────────────────────┬───────────────────────┘  │
│                                                   │                          │
│                            ┌──────────────────────▼───────────────────────┐  │
│                            │  downloader-multisite (source-agnostic)      │  │
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
| Azure Data Factory | Fabric data movement |
| Virtual Network | Network isolation with private endpoints |

**Estimated cost:** ~$180/month

## Deployment

### Prerequisites

- Azure CLI installed and authenticated
- Contributor access to target subscription
- Resource group created

### Deploy

```bash
# Set your subscription
az account set --subscription "<subscription-id>"

# Create resource group
az group create \
  --name rg-dte-noticeapp-eus2-mx01 \
  --location eastus2

# Deploy infrastructure
az deployment group create \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json
```

### Preview Changes

```bash
az deployment group what-if \
  --resource-group rg-dte-noticeapp-eus2-mx01 \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json
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

If the new site uses an existing `parserModel` → no workflow change is needed; just upload the registry blob. If it requires a new shape, add a case to `Dispatch_By_ParserModel` in `scanner-multisite.json` and add a regex branch in `infra/workflows/discover-bus.js`.

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
│   ├── modules/
│   │   ├── storage.bicep             # Blob Storage with lifecycle
│   │   ├── keyvault.bicep            # Key Vault with RBAC
│   │   ├── logicapp-standard.bicep   # Logic Apps Standard
│   │   ├── vnet.bicep                # Virtual Network
│   │   ├── private-endpoints.bicep   # Private endpoints
│   │   ├── foundry.bicep             # Azure AI Foundry
│   │   └── datafactory.bicep         # Data Factory
│   └── workflows/
│       ├── scanner-multisite.json    # Scanner workflow (v4 — discovery + dispatch)
│       ├── discover-bus.js           # Inline JS used by scanner discovery action
│       ├── _build_scanner.js         # Build helper: embeds discover-bus.js into scanner JSON
│       ├── downloader-multisite.json # Downloader workflow definition
│       └── parser-multisite.json     # AI parser workflow
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
- [ ] Fabric Lakehouse connection
- [ ] AI-powered HTML parsing (Phase 3)

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
