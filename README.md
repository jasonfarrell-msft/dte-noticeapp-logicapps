# Critical Notice Extraction Engine

A low-code/no-code Azure solution that extracts critical notices from natural gas pipeline operator websites and stores them in Microsoft Fabric for downstream analytics.

## Overview

This system monitors **30 pipeline operator business units** across two major sources:
- **Enbridge Infopost** (25 units) — HTML scraping
- **TC Energy Connects** (5 units) — JSON API

Critical notices are polled every 15 minutes, deduplicated, and stored in Azure Blob Storage with a unified schema ready for Microsoft Fabric ingestion.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AZURE LOGIC APPS                                │
│                                                                              │
│   ┌───────────────────┐    ┌──────────────────────────────────────────────┐  │
│   │  Recurrence       │───▶│  scanner-multisite                           │  │
│   │  (Every 15 min)   │    │                                              │  │
│   └───────────────────┘    │  ┌────────────────┐   ┌────────────────┐     │  │
│                            │  │ Enbridge       │   │ TCeConnects    │     │  │
│                            │  │ (25 units)     │   │ (5 units)      │     │  │
│                            │  │ HTML scraping  │   │ JSON API       │     │  │
│                            │  └───────┬────────┘   └───────┬────────┘     │  │
│                            └──────────┼────────────────────┼──────────────┘  │
│                                       │                    │                 │
│                            ┌──────────▼────────────────────▼──────────────┐  │
│                            │  downloader-multisite                        │  │
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

### Enbridge Infopost (25 Business Units)

| Code | Pipeline Name |
|------|--------------|
| AG | Algonquin Gas Transmission |
| TE | Texas Eastern |
| STT | Sabal Trail |
| SESH | Southeast Supply Header |
| ET | East Tennessee |
| ... | [See full list in config](infra/config/sites.json) |

### TC Energy Connects (5 Business Units)

| Code | Asset ID | Pipeline Name |
|------|----------|--------------|
| ANR | 3005 | ANR Pipeline Company |
| TCO | 51 | Columbia Gas Transmission |
| CGT | 14 | Columbia Gulf Transmission |
| MPC | 26 | Midwestern Gas Transmission |
| NBPL | 3029 | Northern Border Pipeline |

## Storage Structure

```
critical-notices/
├── notices/                     # Canonical notice metadata (JSON)
│   ├── enbridge/{pipeline}/
│   └── tceconnects/{pipeline}/
├── raw/                         # Raw HTML content
│   ├── enbridge/{date}/{pipeline}/
│   └── tceconnects/{date}/{pipeline}/
├── tracking/                    # Change detection state
├── indices/daily/               # Daily indexes for reporting
└── config/sites.json            # Multi-site configuration
```

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

The multi-site configuration lives in [`infra/config/sites.json`](infra/config/sites.json):

```json
{
  "sites": {
    "enbridge": {
      "type": "html-scraper",
      "businessUnits": [/* 25 units */]
    },
    "tceconnects": {
      "type": "json-api",
      "businessUnits": [/* 5 units */]
    }
  }
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

1. **Scanner** runs every 15 minutes
2. For each business unit, fetches the notice list
3. Extracts notice IDs and checks if already captured (HEAD request)
4. **Downloader** fetches new notices only (deduplication)
5. Stores raw HTML and canonical JSON metadata
6. Updates daily index for efficient querying
7. Data Factory pushes to Microsoft Fabric Lakehouse

## Project Structure

```
├── infra/
│   ├── main.bicep                    # Main deployment orchestration
│   ├── main.parameters.json          # Environment parameters
│   ├── config/
│   │   └── sites.json                # Multi-site configuration
│   ├── modules/
│   │   ├── storage.bicep             # Blob Storage with lifecycle
│   │   ├── keyvault.bicep            # Key Vault with RBAC
│   │   ├── logicapp-standard.bicep   # Logic Apps Standard
│   │   ├── vnet.bicep                # Virtual Network
│   │   ├── private-endpoints.bicep   # Private endpoints
│   │   ├── foundry.bicep             # Azure AI Foundry
│   │   └── datafactory.bicep         # Data Factory
│   └── workflows/
│       ├── scanner-multisite.json    # Scanner workflow definition
│       ├── downloader-multisite.json # Downloader workflow definition
│       └── parser-multisite.json     # AI parser workflow
├── infrastructure-plan.md            # Detailed architecture documentation
└── README.md                         # This file
```

## Implementation Status

- [x] Site analysis and API discovery
- [x] Unified storage schema design
- [x] Multi-site scanner workflow
- [x] Multi-site downloader workflow
- [x] VNet-isolated infrastructure (Bicep)
- [x] Azure AI Foundry integration
- [ ] Full deployment and testing
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
