# Plan: Replace the Node-Based Gmail MCP Server with a Python-Based Gmail Tool

*Project: PersonalAssistant — Azure Container Apps deployment. This is a planning document only; no files have been changed.*

Local testing repeatedly showed the Gmail MCP server (`@gongrzhe/server-gmail-autoauth-mcp`) failing every OAuth token refresh with "Invalid response body ... Premature close", while curl, Python `requests`, and Node's own `fetch`/`http2` all completed the identical request cleanly in the same container using the same real credentials. Disabling checksum offload on the WSL virtual adapter was also tested and ruled out. The evidence points to a bug specific to the `node-fetch` library used internally by that npm package (confirmed independently by a matching GitHub issue on a plain Linux VPS with no WSL2 involved). The plan below replaces that dependency with a Python-based Gmail tool, built on the same HTTP stack already proven to work.

## Phase A — Scope the Replacement Precisely

1. **Determine exactly which Gmail capabilities the agent actually needs**, rather than replicating the entire MCP server's tool surface. `search_emails` is confirmed in use in every test call. The system prompt implies reading email content ("summarize and triage emails") and drafting replies ("Draft replies... but never send without confirmation"). The existing `filter_tools` list in `02_stream_server.py` (`delete_email`, `batch_modify_emails`, `batch_delete_emails`, `delete_label`, `delete_filter`) is a useful checklist of destructive tools to deliberately not implement, rather than filter out after the fact. Minimum viable set: `search_emails`, `read_email`, and `create_draft` (never `send_email`, to preserve the confirm-before-sending behavior structurally).

2. **Confirm the token file's actual shape** — already partly validated (an earlier diagnostic script found `refresh_token` at the top level of `token.json` and completed a real refresh). Before building, fully inspect `gcp-oauth.keys.json` and `token.json` (`client_id`, `client_secret`, `token_uri`, granted scopes) to confirm they map cleanly onto what `google-auth` / `google-api-python-client` expect.

3. **Confirm the OAuth scopes already granted** cover what's needed (e.g. `gmail.readonly` and `gmail.compose`/`gmail.modify` for drafts). If the original authorization only granted a narrower scope than the MCP server's default, that would surface now and might require one re-authorization with the correct scopes.

## Phase B — Design the Replacement

4. **New tools live in `scripts/base_tools.py`** (or a new `scripts/gmail_tools.py`, imported the same way), as plain LangChain `@tool`-decorated functions — matching the existing pattern used for `web_search` and `get_weather`.

5. **Credential loading design**: a small helper that reads `client_id`/`client_secret` from `gcp-oauth.keys.json` and `refresh_token` from `token.json` (same paths already used: `/home/appuser/.gmail-mcp/...` in the container), builds a `google.oauth2.credentials.Credentials` object, and refreshes it via `google.auth.transport.requests.Request()` — the exact call already proven to work end-to-end with real credentials in this container.

6. **Decide refresh caching strategy**: refresh once at backend startup (during `lifespan`/`get_tools()`) and reuse the in-memory credentials object for the process lifetime, matching how the original MCP server behaved as a long-lived process. Google's client libraries handle expiry/re-refresh internally when the same `Credentials` object is reused.

7. **Gmail API client**: build once via `googleapiclient.discovery.build('gmail', 'v1', credentials=creds)`, reused across tool calls rather than rebuilt each time.

8. **Map each planned tool to a concrete Gmail API call**:
   - **`search_emails(query)`** → `users().messages().list(userId='me', q=query)`, then optionally `users().messages().get(...)` for snippets, to match what `search_emails` currently returns.
   - **`read_email(message_id)`** → `users().messages().get(userId='me', id=message_id, format='full')`, with body decoding (Gmail API returns base64url-encoded MIME parts).
   - **`create_draft(to, subject, body)`** → `users().drafts().create(...)`, never send, preserving the confirm-first behavior at the tool level rather than trusting the prompt alone.

## Phase C — Wire It Into the App

9. **`server/02_stream_server.py`**: in `get_tools()`, stop requesting `"gmail"` from `utils.load_mcp_config(...)` (keep `"google-sheets"`, which works fine via `uvx`/Python already). Add the new Gmail tool functions directly to the tools list alongside `base_tools.web_search` and `base_tools.get_weather`.

10. **Update `filter_tools`**: remove the now-irrelevant Gmail entries (`delete_email`, `batch_modify_emails`, `batch_delete_emails`, `delete_label`, `delete_filter`) — those tools will simply never exist in the new implementation.

11. **`scripts/mcp_config.container.json` and `scripts/mcp_config.json`**: remove the `"gmail"` entry from both (or leave it in `mcp_config.json` unused locally, since only the container config strictly needs cleanup).

12. **`scripts/prompts.py`**: review `get_assistant_prompt()`'s Gmail-related guidance line — likely stays accurate as-is since it describes intended behavior rather than literal tool names, but worth a pass to confirm no other prompt text references MCP-specific tool names that no longer exist.

## Phase D — Dependency and Docker Cleanup

13. **`requirements-backend.txt`**: add `google-api-python-client`, `google-auth`, `google-auth-httplib2` — pinned to versions matched against what's already in the local `.venv`, the same approach used for C4.

14. **`Dockerfile.backend`**: since Gmail no longer runs via `npx`, and `google-sheets` still uses `uvx` (not Node), the Node.js/npm `apt-get install` block becomes unnecessary — a meaningful simplification (smaller image, faster build, and removes the exact runtime that had the bug).

## Phase E — Testing Sequence

15. **Unit-level check first**: a standalone script (run via `docker compose exec backend python ...`, same style as earlier diagnostics) that loads credentials, refreshes them, and calls `search_emails`'s underlying Gmail API logic directly — confirming the plumbing works before wiring it into the agent.

16. **Integration test via `chat_stream`**: rebuild the backend image, restart the stack, and retest with a fresh `thread_id` (same discipline as before) — first for search, then read, then draft creation.

17. **Regression check for Sheets**: since this changes `02_stream_server.py` and the MCP config files, re-verify the Google Sheets flow still works too (not yet tested at all in this debugging session).

## Phase F — Fallback

18. **Keep the original `mcp_config.json` (local, uncontainerized) Gmail entry untouched** as a reference/fallback, in case a future npm release of `@gongrzhe/server-gmail-autoauth-mcp` fixes the underlying `node-fetch` bug and reverting is preferred — no need to delete history, just stop routing through it in the container path.

---

*This document records the plan only. No project files have been modified.*
