# SKILL: Bicep Tag Propagation Pattern

**Category:** Infrastructure as Code  
**Stack:** Azure Bicep  
**Applies To:** All Bicep module projects

---

## Pattern: Centralized Tag Definition with Module Pass-Through

### Problem

Azure resources must carry consistent tags (e.g., `SecurityControl`, `Environment`, `Project`) across all deployed resources. Repeating tag definitions in every module leads to drift and inconsistency.

### Solution

Define tags once at the top-level orchestration file and pass the `tags` object through to every module as a parameter.

---

## Implementation

### 1. Define Tags Centrally in `main.bicep`

```bicep
@description('Tags to apply to all resources')
param tags object = {
  Project: 'My Project'
  Environment: environment
  ManagedBy: 'Bicep'
  SecurityControl: 'Ignore'
}
```

Also set them explicitly in `main.parameters.json` to ensure the value is locked in for a given environment:

```json
"tags": {
  "value": {
    "Project": "My Project",
    "Environment": "prod",
    "ManagedBy": "Bicep",
    "SecurityControl": "Ignore"
  }
}
```

### 2. Accept Tags in Every Module

Every module should declare a `tags` parameter with an empty object default (so it can be used standalone):

```bicep
@description('Tags to apply to resources')
param tags object = {}
```

### 3. Apply Tags on Every Taggable Top-Level Resource

```bicep
// Simple pass-through
resource myResource 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: accountName
  location: location
  tags: tags
  ...
}
```

### 4. Use `union()` When a Module Adds Supplemental Tags

When a module wants to add its own resource-specific tags on top of the shared set, use `union()`:

```bicep
resource myApp 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  tags: union(tags, { Service: 'MyWorkflow' })
  ...
}
```

`union()` merges both objects. Shared tags from `main.bicep` are preserved; the local key is appended. If there is a key collision, the second (right-hand) object wins.

### 5. Pass Tags at Every Module Call Site in `main.bicep`

```bicep
module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  params: {
    location: location
    tags: tags          // <-- always pass the shared tag object
    storageAccountName: storageAccountName
  }
}
```

---

## What NOT to Tag

ARM/Bicep child resources that are embedded under a parent do not support tags. Skip tagging on:

- `Microsoft.Storage/storageAccounts/blobServices` (child of storage account)
- `Microsoft.Storage/storageAccounts/blobServices/containers`
- `Microsoft.Storage/storageAccounts/managementPolicies`
- `Microsoft.KeyVault/vaults/secrets`
- `Microsoft.DataFactory/factories/linkedservices`
- `Microsoft.DataFactory/factories/datasets`
- `Microsoft.DataFactory/factories/pipelines`
- `Microsoft.DataFactory/factories/integrationRuntimes`
- `Microsoft.Sql/servers/firewallRules`
- `Microsoft.Sql/servers/azureADOnlyAuthentications`
- `Microsoft.Network/privateEndpoints/privateDnsZoneGroups`

---

## Deploy Script Consideration

If your deploy script uses `az deployment group create`, **do not** add `--tags` at the CLI level. Tags belong in Bicep and the parameters file. Adding `--tags` at the CLI level tags only the deployment resource, not the Azure resources inside it.

```powershell
# Correct — let Bicep handle all tagging
az deployment group create `
    --name $DeploymentName `
    --resource-group $ResourceGroupName `
    --template-file $TemplateFile `
    --parameters $ParametersFile
```

---

## Project Usage (Critical Notice Ingestion)

- **Tag applied:** `SecurityControl: 'Ignore'`
- **Defined in:** `infra/main.bicep` (param default) and `infra/main.parameters.json`
- **Propagated to:** All 9 modules (vnet, storage, keyvault, logicapp-standard, logicapp, datafactory, private-endpoints, sql, foundry)
- **Deploy script:** `infra/scripts/deploy-infra.ps1` — no CLI-level `--tags`, relies entirely on Bicep
- **Decision:** `.squad/decisions/inbox/grace-security-tag.md`
