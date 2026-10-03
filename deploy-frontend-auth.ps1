<#
.SYNOPSIS
  Deploys (or redeploys) the pa-frontend Azure Container App and locks it down with
  Microsoft Entra ID sign-in (sections 5.9 and 5.11).

.PARAMETER ImageTag
  The pa-frontend image tag in ACR to deploy. Defaults to "v1".

.PARAMETER ForceAuthSetup
  Re-runs the Entra ID / Easy Auth setup (Part 2) even if auth already looks enabled -
  useful for rotating the client secret. Without this switch, Part 2 is skipped once
  auth is already configured, so re-running this script to ship a new frontend image
  doesn't keep minting new Entra ID client secrets for no reason.

.NOTES
  TWO GAPS IN THE AZURE CLI THAT THIS SCRIPT WORKS AROUND (found by hand, the slow way):

  1. `az ad app create` does NOT create the corresponding service principal. Until you
     also run `az ad sp create --id <appId>`, the app never appears under Entra ID >
     Enterprise Applications, so there's nothing to set "Assignment required" on.

  2. `az ad app create` does NOT enable ID token issuance on the registration, which
     Container Apps' built-in auth (Easy Auth) needs for its OIDC callback exchange.
     Without `--enable-id-token-issuance true`, sign-in succeeds at Microsoft's side
     and then 401s at your own /.auth/login/aad/callback URL - a confusing failure
     that looks like a secret/config mismatch but isn't.

  ONE STEP IS STILL MANUAL BY DESIGN (printed at the end of Part 2 on first run):
  setting "Assignment required = Yes" and assigning your own user, in the Portal.
  Doing this via raw Microsoft Graph calls in PowerShell means hand-escaping nested
  JSON for a 30-second, one-time task - not worth the fragility given everything else
  in this deployment that's already gone wrong from over-automating fiddly bits.

  ASSUMES: pa-backend is already deployed (reads its FQDN for BACKEND_URL), and Phase 3
  (resource group, ACR, managed identity, environment) already exists.
#>

param(
    [string]$ImageTag = "v1",
    [switch]$ForceAuthSetup
)

$SUBID            = "f03d3c03-0930-437d-9d3c-0df2b7e8757e"
$RG               = "rg-personal-assistant"
$ENVN             = "cae-personal-assistant"
$ACR              = "acrpersonalassistant01"
$IDN              = "id-personal-assistant"
$APP_DISPLAY_NAME = "pa-frontend-auth"

az login
az account set --subscription $SUBID

$IDID = az identity show -g $RG -n $IDN --query id -o tsv
if (-not $IDID) { throw "Managed identity '$IDN' not found in '$RG' - has Phase 3 been run?" }

# ============================================================
# PART 1 - Deploy / update the frontend container app (5.9)
# ============================================================

$BACKEND_FQDN = az containerapp show -n pa-backend -g $RG --query properties.configuration.ingress.fqdn -o tsv
if (-not $BACKEND_FQDN) { throw "pa-backend not found or has no ingress FQDN - deploy the backend first." }

$frontendExists = az containerapp show -n pa-frontend -g $RG --query name -o tsv 2>$null

if (-not $frontendExists) {
    Write-Host "Creating pa-frontend..."
    az containerapp create -n pa-frontend -g $RG --environment $ENVN `
      --image "$ACR.azurecr.io/pa-frontend:$ImageTag" `
      --user-assigned $IDID --registry-server "$ACR.azurecr.io" --registry-identity $IDID `
      --ingress external --target-port 8501 `
      --cpu 0.5 --memory 1.0Gi --min-replicas 1 --max-replicas 1 `
      --env-vars "BACKEND_URL=https://$BACKEND_FQDN"
} else {
    Write-Host "pa-frontend already exists - updating image and backend URL..."
    az containerapp update -n pa-frontend -g $RG `
      --image "$ACR.azurecr.io/pa-frontend:$ImageTag" `
      --set-env-vars "BACKEND_URL=https://$BACKEND_FQDN"
}

$FRONTEND_FQDN = az containerapp show -n pa-frontend -g $RG --query properties.configuration.ingress.fqdn -o tsv
Write-Host "Frontend URL: https://$FRONTEND_FQDN"

# ============================================================
# PART 2 - Entra ID app registration + Easy Auth (5.11)
# ============================================================

$authStatus = az containerapp auth show -n pa-frontend -g $RG --query "globalValidation.unauthenticatedClientAction" -o tsv 2>$null

if ($authStatus -eq "RedirectToLoginPage" -and -not $ForceAuthSetup) {
    Write-Host "Auth is already configured and enabled on pa-frontend - skipping Part 2."
    Write-Host "(Re-run with -ForceAuthSetup to rotate the client secret or redo this step.)"
}
else {
    $REDIRECT_URI = "https://$FRONTEND_FQDN/.auth/login/aad/callback"
    $appId = az ad app list --display-name $APP_DISPLAY_NAME --query "[0].appId" -o tsv
    $isNewApp = -not $appId

    if ($isNewApp) {
        Write-Host "Creating Entra ID app registration '$APP_DISPLAY_NAME'..."
        $appId = az ad app create --display-name $APP_DISPLAY_NAME --sign-in-audience AzureADMyOrg --web-redirect-uris $REDIRECT_URI --query appId -o tsv

        # Gap 1 workaround - see script header.
        az ad sp create --id $appId | Out-Null

        # Gap 2 workaround - see script header.
        az ad app update --id $appId --enable-id-token-issuance true
    }
    else {
        Write-Host "Entra ID app '$APP_DISPLAY_NAME' already exists (appId: $appId) - reusing it."
        # Keep the redirect URI in sync in case the frontend FQDN ever changed
        # (e.g. the container app was deleted and recreated).
        az ad app update --id $appId --web-redirect-uris $REDIRECT_URI
    }

    $clientSecret = az ad app credential reset --id $appId --append --query password -o tsv
    $tenantId = az account show --query tenantId -o tsv

    az containerapp auth microsoft update -n pa-frontend -g $RG `
      --client-id $appId --client-secret $clientSecret `
      --tenant-id $tenantId --yes

    az containerapp auth update -n pa-frontend -g $RG --enabled true `
      --unauthenticated-client-action RedirectToLoginPage

    # Auth config changes need a restart to take effect - found the hard way.
    $latestRevision = az containerapp revision list -n pa-frontend -g $RG --query "[0].name" -o tsv
    az containerapp revision restart -n pa-frontend -g $RG --revision $latestRevision

    if ($isNewApp) {
        Write-Host "`nACTION NEEDED (one-time, manual - see script header for why this isn't scripted):"
        Write-Host "  1. Portal > Microsoft Entra ID > Enterprise applications > $APP_DISPLAY_NAME"
        Write-Host "  2. Manage > Properties > Assignment required? > Yes > Save"
        Write-Host "  3. Users and groups > Add user/group > select your own account > Assign"
        Write-Host "Sign-in will redirect correctly before this, but anyone in the tenant could"
        Write-Host "sign in until the assignment step above is done."
    }
}

Write-Host "`nDone. Verify from a fresh/incognito window: https://$FRONTEND_FQDN"
