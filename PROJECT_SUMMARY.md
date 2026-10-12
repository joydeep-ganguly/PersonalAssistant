# PersonalAssistant — Project Thread Summary

_Last updated: 2026-10-09_

## Project Context
Local agentic AI app ("PersonalAssistant" — Gmail + Google Sheets MCP tools + Gemini API, FastAPI backend + Streamlit frontend), now **fully deployed to Azure Container Apps** as a showcase (non-production-grade) deployment, per `azure-container-apps-deployment.md`. Working model throughout: the user implements and runs every command themselves, with every change reviewed before it was applied.

This document rolls up two major efforts: **(1) replacing the buggy Node-based Gmail MCP server with a Python-based Gmail tool**, and **(2) the full Azure Container Apps deployment**, including post-deployment fixes and cost/scaling tuning.

---

## Effort 1 — Gmail Tool Replacement (COMPLETE, all 6 phases A–F)

### Background
The Node-based Gmail MCP server (`@gongrzhe/server-gmail-autoauth-mcp`) failed inside Docker with a persistent `Error: Invalid response body while trying to fetch https://oauth2.googleapis.com/token: Premature close`. Root cause: the package's internal use of `node-fetch`, a library with known gzip/chunked-response bugs — corroborated by an identical failure reported independently on plain Linux (no WSL2) in an unrelated GitHub issue. Since the bug was Linux-reproducible, it was judged too risky to carry into Azure's Linux containers, so a full replacement was built instead of patching around it.

### Resolution
Replaced the Gmail MCP server entirely with a **Python-based Gmail tool** (`scripts/gmail_tools.py`) built on `google-auth` / `google-api-python-client` — the same stack already proven to complete a real OAuth token refresh cleanly in the container. Google Sheets (served via `uvx`, not Node) was unaffected and left as-is.

### Phases completed
- **Phase A — Scope**: confirmed minimum viable tool set (`search_emails`, `read_email`, `create_draft` — never `send_email`); confirmed credential field mapping: `gcp-oauth.keys.json` (client_id/secret/token_uri, shared with Sheets) + `credentials.json` (Gmail's own refresh token, scopes `gmail.modify` + `gmail.settings.basic`).
- **Phase B — Design**: approved design — `load_gmail_credentials()`, `init_gmail()` (module-level singletons), `_extract_body()` MIME walker, three `@tool`-decorated functions in `scripts/gmail_tools.py`.
- **Phase C — Wire into the app**: `server/02_stream_server.py` updated — drops `"gmail"` from the MCP config, calls `gmail_tools.init_gmail()`, adds `search_emails`/`read_email`/`create_draft` directly as LangChain tools alongside the Google Sheets MCP tools; `filter_tools` trimmed to `["update_cells"]`. Import error (`googleapiclient.discovery` not found) fixed via `pip install -r requirements-backend.txt`.
- **Phase D — Dependency/Docker cleanup**: `requirements-backend.txt` gained `google-auth`, `google-auth-httplib2`, `google-api-python-client`; `Dockerfile.backend`'s Node.js/npm install block removed entirely (kept `uv`/`uvx` for Google Sheets).
- **Phase E — Testing**: standalone smoke test (`scripts/smoke_test_gmail.py`) passed; local (non-Docker) smoke test required temporary env-var overrides for credential paths — later found to be the cause of a Docker Compose backend crash when those same overrides leaked into the container via `.env`; fixed by removing them from `.env` (container uses its own correct default paths via the volume mount) and recreating the container. Full `docker compose up --build` then ran clean end-to-end, including Google Sheets (previously untested all session).
- **Phase F — Fallback**: original local `scripts/mcp_config.json` left untouched (still has the old Node Gmail entry, unused) as a reference; `scripts/mcp_config.container.json` has `"gmail"` removed, only `"google-sheets"` remains.

**Result**: Gmail and Sheets both fully functional in Docker, clearing the path to Azure deployment.

---

## Effort 2 — Azure Container Apps Deployment (COMPLETE)

Deployed per `azure-container-apps-deployment.md`, Section 6 plan, phase by phase.

### 3. Azure foundation — ✅ Complete
Resource group `rg-personal-assistant` (region `centralindia`), Azure Container Registry (`acrpersonalassistant01`), Azure Key Vault (`kv-pa-assistant-01`, RBAC-based secret access for `google-api-key`, `ollama-api-key`, `weather-api-key`), user-assigned managed identity (`id-personal-assistant`), Azure Files share (`pa-oauth`, mounted into containers for OAuth credential persistence), Container Apps environment (`cae-personal-assistant`).

### 4/5. Deploy — ✅ Complete

**Backend (`pa-backend`)** — hit a major blocker:
- `az containerapp create --yaml backend.yaml` repeatedly failed with `400 Bad Request: "The JSON value could not be converted to System.Boolean. Path: $ | LineNumber: 0 | BytePositionInLine: 4."`
- Ruled out: UTF-8 BOM (hex-dump confirmed none), stale CLI extension (update made no difference), preview vs. stable API version (same error on both via raw `az rest`).
- **Root cause** (found via bisection — incrementally re-adding config blocks to a minimal working body): `az containerapp create --yaml` serializes to JSON and emits explicit `null` for every unset optional field. Specifically `configuration.ingress.allowInsecure: null` is rejected by this API version's deserializer as an invalid boolean. The generic `Path: $ | LineNumber: 0` error is just ASP.NET losing precise location info during the type-coercion failure — not a whole-document error.
- **Fix, now standard practice**: never use `az containerapp create --yaml`. Hand-build a JSON request body containing only fields with real values (omit unset optionals entirely, never null them), and deploy via `az rest --method put` against a stable, non-preview API version (e.g. `2025-07-01`). Confirmed working — `provisioningState: Succeeded`, app loads tools cleanly in logs.
- `backend.yaml` was identified as the exact trigger file for this bug and deleted (no longer needed now the JSON/`az rest` approach is standard).
- This fix is encoded reusably in **`deploy-backend.ps1`** (PowerShell script at project root), so the backend can be redeployed from scratch without re-deriving the bisection.

**Frontend (`pa-frontend`)** — deployed successfully via plain `az containerapp create` (no YAML bug encountered here); Streamlit URL confirmed working. Encoded reusably in **`deploy-frontend-auth.ps1`**.

### 5.10/5.11 — Entra ID (Azure AD) authentication ("Easy Auth") — ✅ Complete
Locked the frontend down to the user's own Microsoft account only (single-tenant, "Assignment required").
- Gap 1: `az ad app create` only creates the app registration, not the Enterprise Application (service principal) — it didn't appear under "Enterprise Applications" until `az ad sp create --id $appId` was run explicitly.
- Gap 2: after sign-in succeeded, the callback (`.auth/login/aad/callback`) returned HTTP 401. Root cause (via web research): `az ad app create` does not enable ID token issuance, which Container Apps' Easy Auth OIDC flow requires. Fixed with `az ad app update --id $appId --enable-id-token-issuance true` (no container restart needed — registration-level change). Confirmed working in both normal and incognito browsing afterward (incognito re-prompts each time due to no persistent cookie — expected, not a bug).
- Manual Portal-only step: assigning the user under "Users and groups" on the Enterprise Application (not exposed via CLI in a scriptable way at the time).
- Both discovered gaps are encoded as explicit workarounds in **`deploy-frontend-auth.ps1`** (idempotent, with a `-ForceAuthSetup` switch), which also prints a reminder for the manual Portal assignment step.

### 6. Verify/secure — ✅ Complete
Full project audit performed against the deployment doc's checklist; no gaps found other than the Google OAuth consent screen issue below (which was outside the doc's original scope).

---

## Post-Deployment Fix — Google OAuth Consent Screen → Production (COMPLETE)

**Problem**: the Google OAuth consent screen was stuck in "Testing" status, which causes refresh tokens to expire after only 7 days — unacceptable for an always-available deployed app.

**Fix process**:
1. The "Publish app" button was greyed out. Root cause (web research): Google now requires an **Application home page** and a **Privacy policy** link, hosted on a registered **Authorized Domain**, before publishing is allowed — even for a solo/personal-use app.
2. Created minimal static pages: `docs/index.html` (homepage — describes the app as a personal single-user tool, links to the GitHub repo and privacy page) and `docs/privacy.html` (privacy policy — describes Gmail/Sheets API access scope, confirms data stays on private Azure infrastructure, contact email `joydeepganguly32@gmail.com`).
3. Pushed to the existing GitHub repo; enabled GitHub Pages (Deploy from branch, `main` / `/docs`).
4. Filled in the consent screen's Branding fields, and added **`joydeep-ganguly.github.io`** (the full subdomain — **not** bare `github.io`) as the Authorized Domain. This exact subdomain requirement was an explicit correction discovered during the process.
5. "Publish app" became clickable; confirmed with the user what pushing to production means (app becomes available to any Google account for sign-in — but this only affects who *can authenticate against the OAuth client*; it does not expose the user's Gmail/Sheets data, which stays behind Azure Container Apps' own Entra ID authentication).
6. Confirmed status now shows **"In production."**
7. Minted fresh OAuth tokens for both Gmail and Sheets (the old ones, issued under "Testing," needed replacing):
   - Gmail: re-ran the Node auth flow to regenerate `credentials.json`.
   - Sheets: re-ran `uvx --with "mcp<2" mcp-google-sheets@latest` to regenerate `token.json`. Hit a `uvx` "not recognized" error locally — `uv`/`uvx` was not installed/on PATH on this machine; found and used the actual binary at an absolute path from a different project's venv (`D:\GenAIByLaxmiKant\AI-Agent-Projects-main\venv\Scripts\uvx.exe`) rather than installing `uv` globally.
   - Saw Google's standard "unverified app" warning screen during re-auth — expected for an app that hasn't gone through Google's full verification review (not required at this scale), and cleared normally.
8. Uploaded both fresh files to the Azure Files share (`pa-oauth`); confirmed via `az storage file list` that both `credentials.json` and `token.json` show current timestamps.
9. Restarted the backend; logs show clean OAuth success with no `invalid_grant` and no refresh-step — confirming the new tokens load correctly.

**Soft/background verification point (not yet confirmed)**: the true proof the 7-day-expiry bug is fixed only arrives around **Oct 11–12, 2026** (8+ days after republishing) — if the backend is still working without `invalid_grant` errors by then, it confirms the "Testing" 7-day clock no longer applies now that the app is in production.

---

## Post-Deployment Tuning — Cost/Scaling for a Showcase Deployment (COMPLETE)

Since this is a showcase (not production) deployment, two cost-saving changes were made, with the explicit constraint that **no project files were to be touched — only Azure-side configuration**:

1. **Container Apps environment confirmed as Consumption plan** (not Workload Profiles) — verified via `az containerapp show` / `workloadProfileName: "Consumption"` in the resource JSON. Implications and CLI/Portal process were discussed; no environment migration was actually needed since it was already Consumption.
2. **`minReplicas` changed from 1 to 0 for both `pa-frontend` and `pa-backend`** — confirmed working via plain CLI:
   ```
   az containerapp update -n pa-frontend -g $RG --min-replicas 0 --max-replicas 1
   az containerapp update -n pa-backend  -g $RG --min-replicas 0 --max-replicas 1
   ```
   No `az rest` workaround was needed for this (unlike the original backend creation bug). This allows both apps to scale to zero when idle, reducing cost; the trade-off is a cold-start delay (and loss of the in-memory chat checkpoint) the next time either app is accessed after scaling down — an accepted trade-off per the project's original R2 decision to keep `InMemorySaver` rather than a persistent store.

**Note for future reference (not yet acted on)**: `deploy-backend.ps1` and `deploy-frontend-auth.ps1` still hardcode `minReplicas: 1` / `--min-replicas 1` in their templates. If either script is re-run unmodified, it will silently reset `minReplicas` back to 1, undoing this change. Update the scripts to `0` before next re-running them, if a from-scratch redeploy is ever needed.

---

## Current State (as of 2026-10-09)
- Gmail + Sheets tools: fully working in Docker and in Azure, via the Python-based Gmail tool and the existing Sheets MCP server.
- Azure deployment: both `pa-backend` and `pa-frontend` live on Container Apps (Consumption plan), frontend protected by Entra ID single-tenant auth, secrets in Key Vault via managed identity, OAuth credentials persisted on Azure Files.
- Google OAuth: consent screen in production; fresh tokens minted and deployed.
- Cost tuning: both apps scale to zero (`minReplicas: 0`) when idle.
- Reusable deployment scripts (`deploy-backend.ps1`, `deploy-frontend-auth.ps1`) exist at the project root for redeploying from scratch, encoding every workaround discovered above — except the `minReplicas` value noted above, which is now stale in those scripts.

## Open / Background Items
- Watch for continued clean Gmail operation past ~Oct 11–12, 2026 as final confirmation the "In production" fix resolved the 7-day refresh-token expiry.
- `deploy-backend.ps1` / `deploy-frontend-auth.ps1` hardcode `minReplicas: 1` — update if a from-scratch redeploy is ever needed, to avoid silently undoing the scale-to-zero change.
