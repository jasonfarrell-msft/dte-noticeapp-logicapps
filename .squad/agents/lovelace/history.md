# Lovelace — History

## Core Context

Project: Critical notice ingestion infrastructure for Enbridge Infopost sites.
Stack: Azure Logic Apps, Blob Storage, Key Vault, Data Factory, Bicep IaC.
User: Jason Farrell

## Learnings

- 2026-04-17: Project initiated. Will need to validate Bicep deployments to rg-dte-noticeapp-eus2-mx01 in East US 2.
- 2026-04-19: Validated captured data against live source APIs. Scanner/downloader working correctly — 1,342 notices captured (1,086 Enbridge, 256 TCeConnects) with 100% match against live APIs. Parser healthy but behind (50/1,342 processed). Storage container is `critical-notices` (with hyphen). Storage firewall blocks external access by default — need to temporarily add IP or use Azure services. Six Enbridge pipelines (BSP, GPL, MCGP, NPC, NXCA, WRGS) have zero notices on source, not missing data.
