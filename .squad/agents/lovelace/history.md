# Lovelace — History

## Core Context

Project: Critical notice ingestion infrastructure for Enbridge Infopost sites.
Stack: Azure Logic Apps, Blob Storage, Key Vault, Data Factory, Bicep IaC.
User: Jason Farrell

## Learnings

- 2026-04-17: Project initiated. Will need to validate Bicep deployments to rg-dte-noticeapp-eus2-mx01 in East US 2.
- 2026-04-19: Validated captured data against live source APIs. Scanner/downloader working correctly — 1,342 notices captured (1,086 Enbridge, 256 TCeConnects) with 100% match against live APIs. Parser healthy but behind (50/1,342 processed). Storage container is `critical-notices` (with hyphen). Storage firewall blocks external access by default — need to temporarily add IP or use Azure services. Six Enbridge pipelines (BSP, GPL, MCGP, NPC, NXCA, WRGS) have zero notices on source, not missing data.
- 2026-04-20: Added infra/scripts/validate-redeploy.ps1 to validate redeploy outputs (tags, workflows, storage backfill, parser outputs, Data Factory assets, optional SQL checks).
- 2026-04-21: Added infra/scripts/validate-seed-package.ps1 to validate local seed packages (notices/, config/sites.json, indices/daily date folders, raw or processed/raw content).
- 2026-04-22: Reviewed setup-environment.ps1 seed modes and RunValidation flow; added local PowerShell syntax validation for infra/scripts to catch setup script issues offline.
- 2026-04-22: Assessed redeploy readiness — project is deployment-ready with comprehensive validation scripts. validate-redeploy.ps1 verifies tags, workflows, 10-day data backfill, config, notices, parser outputs, and optional SQL. setup-environment.ps1 supports Backfill mode (direct storage-to-storage) or LocalSeed mode (staged import) with built-in validation via -RunValidation flag. Key validation files: validate-local.ps1 (offline syntax), validate-seed-package.ps1 (pre-import checks), validate-redeploy.ps1 (post-deployment verification). Identified gaps: no dry-run mode for backfill, no pre-backfill source validation, parser health metrics missing. Recommended pre-flight: validate-local.ps1 + source data check + setup-environment.ps1 with -RunValidation.
- 2026-05-12: **Orchestration Log Created**: Documented Lovelace's redeploy validation assessment in .squad/orchestration-log/2026-05-12T18-29-30Z-lovelace.md with assessment verdict (DEPLOYMENT-READY with pre-flight conditions), validation strengths, recommended sequences, and identified minor gaps (no dry-run mode, no pre-backfill source validation, parser health metrics missing). Merged decision documents into main decisions.md. Assessment provides clear path to safe redeploy with validation.

