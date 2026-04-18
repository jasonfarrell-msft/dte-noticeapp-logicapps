# Hopper — History

## Core Context

Project: Critical notice ingestion infrastructure for Enbridge Infopost sites.
Stack: Azure Logic Apps, Blob Storage, Key Vault, Data Factory, Bicep IaC.
User: Jason Farrell

## Learnings

- 2026-04-17: Project initiated. 25 business units to poll from Enbridge. Polling every 15 minutes. Storage account name: stdtenoticeappeus2mx01. Fabric handled by separate team — we just push to Data Factory.

- 2024-04-18: **Parser architecture decision.** Designed no-code HTML parsing solution using Logic Apps + Microsoft Foundry (GPT-4o). Event Grid triggers on new blobs in raw/, calls GPT API to extract structured fields, writes to parsed/ folder. Cost-effective (~$17/month for 1,800 notices). Key tradeoffs: GPT-4o chosen over Azure Document Intelligence (more flexible, cheaper) and custom code (violates no-code requirement). Prompt engineering with temperature=0.1 and JSON response format ensures deterministic output. Error handling: retry policy + failed/ folder for manual review. Target accuracy: 95%+. Status: Awaiting approval from Jason. Next: Grace implements PoC with 10 sample notices.
