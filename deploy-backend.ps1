<#
.SYNOPSIS
  Deploys (or redeploys) the pa-backend Azure Container App.

.NOTES
  WHY THIS SCRIPT EXISTS, NOT "az containerapp create --yaml":

  `az containerapp create --yaml backend.yaml` converts the YAML to JSON internally and
  that conversion emits an explicit JSON `null` for every optional property you didn't
  set - including "configuration.ingress.allowInsecure", which is boolean-typed. The
  Container Apps resource provider's deserializer rejects a `null` there with:

    "The JSON value could not be converted to System.Boolean.
     Path: $ | LineNumber: 0 | BytePositionInLine: 4."

  (The generic root-level path/line in that error is just ASP.NET losing the precise
  nested location - it is NOT a sign the problem is at the start of the document.)

  This was confirmed by bisection: a hand-written JSON body that only includes fields
  with real values (never nulls out unset optional ones) succeeds every time, at
  multiple stable API versions, with the extension both old and freshly updated - ruling
  out encoding, extension staleness, and API-version age as the cause.

  WHAT THIS SCRIPT ASSUMES ALREADY EXISTS (Phase 3 "Azure foundation" - not created here):
    - Resource group, Container Registry, managed identity, Key Vault (with the three
      secrets: google-api-key, ollama-api-key, weather-api-key), storage account + file
      share (with the three Gmail OAuth files uploaded), and the Container Apps
      environment with that file share registered as "pa-oauth".
    - An image already pushed to ACR at the tag referenced by $IMAGE_TAG below
      (az acr build -r $ACR -t pa-backend:$IMAGE_TAG -f Dockerfile.backend .)

  This script only (re)deploys the pa-backend container app itself.
#>

# ---- 1. Sign in (skip if this session is already logged in) ----
az login
az account set --subscription "f03d3c03-0930-437d-9d3c-0df2b7e8757e"

# ---- 2. Variables - resolved from existing resources, nothing created here ----
$SUBID     = "f03d3c03-0930-437d-9d3c-0df2b7e8757e"
$RG        = "rg-personal-assistant"
$ENVN      = "cae-personal-assistant"
$ACR       = "acrpersonalassistant01"
$KV        = "kv-pa-assistant-01"
$IDN       = "id-personal-assistant"
$LOC       = "centralindia"
$IMAGE_TAG = "v1"   # bump this (and run az acr build first) when deploying a new image

$IDID = az identity show -g $RG -n $IDN --query id -o tsv
if (-not $IDID) {
    throw "Managed identity '$IDN' not found in resource group '$RG' - has Phase 3 been run?"
}

# ---- 3. Build the request body by hand: only fields with real values, no explicit nulls ----
$body = @"
{
  "location": "$LOC",
  "identity": {
    "type": "UserAssigned",
    "userAssignedIdentities": {
      "$IDID": {}
    }
  },
  "properties": {
    "environmentId": "/subscriptions/$SUBID/resourceGroups/$RG/providers/Microsoft.App/managedEnvironments/$ENVN",
    "configuration": {
      "activeRevisionsMode": "Single",
      "ingress": {
        "external": false,
        "targetPort": 8002
      },
      "registries": [
        {
          "server": "$ACR.azurecr.io",
          "identity": "$IDID"
        }
      ],
      "secrets": [
        {
          "name": "google-api-key",
          "identity": "$IDID",
          "keyVaultUrl": "https://$KV.vault.azure.net/secrets/google-api-key"
        },
        {
          "name": "ollama-api-key",
          "identity": "$IDID",
          "keyVaultUrl": "https://$KV.vault.azure.net/secrets/ollama-api-key"
        },
        {
          "name": "weather-api-key",
          "identity": "$IDID",
          "keyVaultUrl": "https://$KV.vault.azure.net/secrets/weather-api-key"
        }
      ]
    },
    "template": {
      "containers": [
        {
          "image": "$ACR.azurecr.io/pa-backend:$IMAGE_TAG",
          "name": "pa-backend",
          "resources": {
            "cpu": 1.0,
            "memory": "2Gi"
          },
          "env": [
            { "name": "GOOGLE_API_KEY", "secretRef": "google-api-key" },
            { "name": "OLLAMA_API_KEY", "secretRef": "ollama-api-key" },
            { "name": "WEATHER_API_KEY", "secretRef": "weather-api-key" }
          ],
          "volumeMounts": [
            { "volumeName": "oauth", "mountPath": "/home/appuser/.gmail-mcp" }
          ],
          "probes": [
            {
              "type": "Startup",
              "httpGet": { "path": "/", "port": 8002 },
              "initialDelaySeconds": 15,
              "periodSeconds": 15,
              "failureThreshold": 10
            },
            {
              "type": "Liveness",
              "httpGet": { "path": "/", "port": 8002 },
              "periodSeconds": 30
            }
          ]
        }
      ],
      "scale": {
        "minReplicas": 1,
        "maxReplicas": 1
      },
      "volumes": [
        {
          "name": "oauth",
          "storageType": "AzureFile",
          "storageName": "pa-oauth",
          "mountOptions": "uid=1000,gid=1000,file_mode=0770,dir_mode=0770"
        }
      ]
    }
  }
}
"@

$bodyPath = Join-Path $PSScriptRoot "backend-deploy-body.generated.json"
$body | Set-Content -Path $bodyPath -Encoding ascii

# ---- 4. Deploy via az rest - bypasses the broken --yaml path entirely ----
az rest --method put `
  --url "https://management.azure.com/subscriptions/$SUBID/resourceGroups/$RG/providers/Microsoft.App/containerApps/pa-backend?api-version=2025-07-01" `
  --body "@$bodyPath"

# ---- 5. Verify ----
Write-Host "`nWaiting before checking provisioning state..."
Start-Sleep -Seconds 10
az containerapp show -n pa-backend -g $RG --query properties.provisioningState -o tsv

Write-Host "`nRecent logs (look for 'Loaded N Tools' and 'Application startup complete'):"
az containerapp logs show -n pa-backend -g $RG --tail 50
