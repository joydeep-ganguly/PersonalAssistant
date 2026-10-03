# PersonalAssistant — Azure Deployment Thread Summary

## Project Context
Local agentic AI app ("PersonalAssistant" — Gmail + Google Sheets MCP tools + Gemini API, FastAPI backend + Streamlit frontend) being deployed to Azure Container Apps per `azure-container-apps-deployment.md`. Working model: user implements/runs commands; I verify via filesystem connector, explain, and provide exact code — never editing project files directly.

## Status by Deployment Phase (per the plan's own table)

**Phase 1 — Prepare code: ✅ Complete, verified**
- C1 (configurable `BACKEND_URL` in Streamlit) — done
- C2 (Linux MCP config path via `MCP_CONFIG_PATH` env var in `scripts/utils.py`) — done
- C3 (in-memory PDF download via `io.BytesIO()` + `st.sidebar.download_button`) — done
- C4 (split, pinned `requirements-backend.txt` / `requirements-frontend.txt`) — done

**Phase 2 — Dockerize: ⚠️ Files built, functionally blocked**
- `Dockerfile.backend`, `Dockerfile.frontend`, `docker-compose.yml`, `.dockerignore` created and verified correct; `docker compose up --build` succeeds.
- **Blocking issue**: Gmail MCP tool calls fail inside the container with `Error: Invalid response body while trying to fetch https://oauth2.googleapis.com/token: Premature close`.
- **Google Sheets has never been tested in this entire session** — open regression check.

**Phase 3 (Azure foundation) onward: not started — deliberately held** until Gmail is fixed and Sheets is confirmed working.

## The Core Bug — Diagnosis Timeline
1. `invalid_grant` on `search_emails` → fixed by re-running `npx @gongrzhe/server-gmail-autoauth-mcp auth` (expired refresh token).
2. `ConnectionRefusedError` / containers `Exited (255)` → Docker Desktop/WSL2 VM corrupted by host sleep → fixed each time via `wsl --shutdown` + Docker Desktop restart.
3. **Persistent `Premature close` error** on every real Gmail tool call, despite:
   - Disabling checksum offload on `vEthernet (WSL (Hyper-V firewall))` — no effect.
   - Full WSL/Docker resets, fresh `thread_id`s — no effect.
   - curl, Python `requests`, and Node's own `fetch`/`http2` all completing the **identical** OAuth refresh request cleanly in the same container with the same real credentials (confirmed via a diagnostic script: `200 461 True`).
4. **Root cause identified**: the Gmail MCP package (`@gongrzhe/server-gmail-autoauth-mcp`) uses `node-fetch` internally (confirmed via `node-domexception` dependency in its npm output) — a library with known gzip/chunked-response bugs, corroborated by an identical failure reported independently on a plain Linux VPS with no WSL2 involved (`gemini-cli` GitHub issue #28440).

## Strategic Decisions Taken
- **Rejected** further WSL2/mirrored-networking fixes — the bug reproduces on plain Linux with no WSL2, so a Windows-network-layer fix wouldn't carry over to Azure's Linux containers anyway, and checksum offload was already ruled out.
- **Rejected** proceeding to Azure (Phase 3) on the assumption Azure's Linux environment would "just work" — same Linux-based failure precedent makes that too risky to deploy on blind.
- **Decided**: replace the Node-based Gmail MCP server with a **Python-based Gmail tool**, built on `google-auth` / `google-api-python-client` — the exact stack already proven to complete a real OAuth refresh in this container. Google Sheets (via `uvx`, not Node) is unaffected and stays as-is.

## Gmail Tool Replacement Plan (delivered as `.docx` and `.md`, not yet implemented)
6 phases, 18 steps:
- **A — Scope**: minimum viable tools = `search_emails`, `read_email`, `create_draft` (never `send_email`); confirm `token.json`/`gcp-oauth.keys.json` field shapes; confirm granted OAuth scopes are sufficient.
- **B — Design**: new tools in `scripts/base_tools.py` (or `scripts/gmail_tools.py`) as LangChain `@tool` functions; credential-loading helper building a `google.oauth2.credentials.Credentials` object; refresh once at startup, reuse in-memory; build Gmail API client once via `googleapiclient.discovery.build`; map each tool to a concrete Gmail API call.
- **C — Wire in**: `02_stream_server.py` drops `"gmail"` from MCP config, adds new tool functions directly; prune now-irrelevant entries from `filter_tools`; remove `"gmail"` from `mcp_config.container.json`; review `prompts.py` for stale tool-name references.
- **D — Cleanup**: add `google-api-python-client`, `google-auth`, `google-auth-httplib2` to `requirements-backend.txt`; drop the Node.js/npm block from `Dockerfile.backend` entirely.
- **E — Testing**: standalone diagnostic script first, then `chat_stream` integration test (search → read → draft), then **regression-test Sheets** (still untested all session).
- **F — Fallback**: leave the original local (non-container) `mcp_config.json` Gmail entry untouched as a reference in case the npm package is fixed upstream later.

## Current Blocker
The filesystem connector (`mcp__remote-devices__Filesystem__*`) has been non-functional across repeated retries, failing with:
```
JSON Schema declares an unsupported dialect ("$schema": "http://json-schema.org/draft-07/schema#")
```
This blocked the start of **Phase A** implementation (reading `02_stream_server.py`, `prompts.py`, and the OAuth credential files to pin down the exact tool set and confirm field/scope compatibility). This is an environment/connector-level issue, not something fixable from this side.

## Next Step (once the connector works, in this thread or a new one)
1. Confirm connector access with a simple directory listing.
2. Read `server/02_stream_server.py` and `scripts/prompts.py` to nail down Gmail tool set (Phase A, step 1).
3. Read `gcp-oauth.keys.json` / `token.json` from `C:\Users\LENOVO\.gmail-mcp` to confirm field structure (Phase A, step 2).
4. Confirm granted OAuth scopes are sufficient (Phase A, step 3).
5. Report findings only — no code changes until the user explicitly moves to Phase B.