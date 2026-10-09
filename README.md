# PersonalAssistant

A personal, single-user agentic AI assistant: a LangChain/LangGraph agent (Google Gemini) with tool access to **Gmail** (search, read, draft) and **Google Sheets** (read/update), served through a FastAPI backend with a Streamlit chat frontend.

This project is a **showcase deployment** — built to demonstrate an end-to-end agentic app running on Azure Container Apps, not a production-grade multi-user service.

## Features
- Conversational agent powered by `ChatGoogleGenerativeAI` (Gemini), built with `create_agent` (LangGraph), using an in-memory (`InMemorySaver`) chat checkpoint.
- **Gmail tools** (`search_emails`, `read_email`, `create_draft`) — implemented directly in Python with `google-auth` / `google-api-python-client` (not an MCP server), for reliability inside Docker/Linux.
- **Google Sheets tools** — served via the `mcp-google-sheets` MCP server (`uvx`), loaded through `langchain-mcp-adapters`.
- Streaming chat responses (NDJSON) from the FastAPI backend to the Streamlit UI.
- PDF report download support from the chat sidebar.

## Architecture
- `server/02_stream_server.py` — FastAPI backend; loads MCP tools + the Gmail Python tools at startup (lifespan), exposes a streaming chat endpoint.
- `server/03_streamlit_client.py` — Streamlit chat frontend, talks to the backend over HTTP.
- `scripts/gmail_tools.py` — Gmail API tool implementations (credential loading, Gmail API client, the three `@tool`-decorated functions).
- `scripts/base_tools.py`, `scripts/utils.py`, `scripts/prompts.py`, `scripts/agent_utils.py` — shared tool/prompt/config helpers.
- `scripts/mcp_config.json` — local (non-container) MCP server config (Gmail entry present but unused — the Gmail MCP server has been replaced; kept only as a historical fallback reference).
- `scripts/mcp_config.container.json` — MCP server config used inside Docker/Azure (Google Sheets only).
- `Dockerfile.backend`, `Dockerfile.frontend`, `docker-compose.yml` — containerization for local Docker runs and the Azure image builds.
- `docs/` — minimal static site (`index.html`, `privacy.html`) served via GitHub Pages, required by Google to publish the OAuth consent screen to production.
- `azure-container-apps-deployment.md` — the full Azure Container Apps deployment plan and reference.
- `Gmail_Tool_Replacement_Plan.md` — the phased plan used to replace the original Node-based Gmail MCP server.
- `Thread_Summary.md` — running history of the project's development and deployment work.
- `deploy-backend.ps1`, `deploy-frontend-auth.ps1` — reusable PowerShell scripts that redeploy the backend and the frontend (incl. Entra ID authentication setup) to Azure Container Apps from scratch.

## Why a custom Gmail tool instead of an MCP server?
The original Node-based Gmail MCP server (`@gongrzhe/server-gmail-autoauth-mcp`) had a reproducible bug (`node-fetch`-related) that broke OAuth token refresh inside Linux containers. It was replaced with a small Python tool built on the official Google API client libraries, which proved reliable in the same environment. See `Thread_Summary.md` for the full diagnosis and replacement history.

## Deployment
The app is deployed to **Azure Container Apps** (Consumption plan):
- `pa-backend` and `pa-frontend` container apps, built via Azure Container Registry.
- Secrets (Gemini/Weather/Ollama API keys) stored in Azure Key Vault, accessed via a user-assigned managed identity.
- OAuth credential files (Gmail + Sheets) persisted on an Azure Files share, mounted into the backend container.
- The frontend is protected by Microsoft Entra ID authentication (Container Apps built-in "Easy Auth"), locked to a single assigned user.
- Both apps scale to zero (`minReplicas: 0`) when idle, to minimize cost for a showcase deployment.

Full step-by-step deployment instructions are in `azure-container-apps-deployment.md`; a condensed, scripted version of the whole process is in `deploy-backend.ps1` and `deploy-frontend-auth.ps1`.

## Local development
1. Copy `.env.example` to `.env` and fill in the required API keys.
2. Install dependencies: `pip install -r requirements-backend.txt -r requirements-frontend.txt`.
3. Run with Docker Compose: `docker compose up --build`, or run the backend (`server/02_stream_server.py`) and frontend (`server/03_streamlit_client.py`) directly with `uvicorn` / `streamlit run`.
4. Gmail and Sheets both require their own OAuth credential files under `~/.gmail-mcp/` (`gcp-oauth.keys.json`, `credentials.json` for Gmail, `token.json` for Sheets) — see `Gmail_Tool_Replacement_Plan.md` for the exact field layout.

## Status
Fully functional end-to-end: Gmail + Sheets tools working locally and in Azure, deployed, authenticated, and cost-tuned. See `Thread_Summary.md` for the complete history and any open follow-up items.
