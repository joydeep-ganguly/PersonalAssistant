# Deploying the Personal Assistant to Azure Container Apps

This guide covers deploying the FastAPI backend and the Streamlit frontend as two separate Azure Container Apps, each on its own port. Scope is a **showcase deployment** — a working, reasonably secured demo of an agentic AI app on Azure Container Apps, not a production system built for scale or high availability. That framing is why the simpler option wins wherever there's a trade-off (see R2 and 5.11).

> **Status:** Nothing in the project has been modified. You are applying the code changes (section 3) and running the Azure CLI steps (section 5) yourself; this file stays as the reference, and I'll walk through any step in detail when you ask.
>
> **All decisions made:** OAuth files live in `C:\Users\LENOVO\.gmail-mcp` (`token.json`, `gcp-oauth.keys.json`, `credentials.json`) · drop Yahoo Finance and Airbnb from the container MCP config · keep Google Calendar in mind for later · you'll pick the Azure region when you get to that step · **Entra ID** for locking down the frontend (not an IP allow-list) · **RAM** (`InMemorySaver`) for chat memory, single replica (not Postgres) — simplest option, consistent with the showcase scope. Section 7 has the full recap.

---

## 1. What the project contains today

```text
PersonalAssistant/
├── .env / .env.example        # API keys (.env is git-ignored)
├── .python-version            # 3.13
├── requirements.txt           # one unpinned file, ~45 packages
├── README.md                  # empty
├── scripts/
│   ├── mcp_config.json        # MCP servers (stdio), Windows paths
│   ├── utils.py               # load_mcp_config()
│   ├── base_tools.py          # web_search (Ollama), get_weather (WeatherAPI)
│   ├── prompts.py             # system prompts
│   └── agent_utils.py         # CLI helper, not used by the server
└── server/
    ├── 02_stream_server.py    # FastAPI backend, port 8002
    ├── 03_streamlit_client.py # Streamlit frontend
    └── pdf_reports/           # PDFs written by the frontend
```

| Component | What it does | Effect on deployment |
|---|---|---|
| `02_stream_server.py` | FastAPI app. `GET /` health message, `POST /chat_stream` streams NDJSON. Loads MCP tools at startup (`lifespan`), uses Gemini via `ChatGoogleGenerativeAI`, keeps chat memory in `InMemorySaver`. | Needs port 8002, a slow startup (MCP tools load first), and a single replica unless memory is moved to a database. |
| `03_streamlit_client.py` | Streamlit chat UI. Calls `http://localhost:8002/chat_stream` (hard-coded). Saves PDFs to `server/pdf_reports/`. | The URL must become configurable. PDFs saved inside a container are unreachable for the user. |
| `mcp_config.json` | Launches the Gmail MCP server with `npx` and the Google Sheets MCP server with `uvx`, as child processes (stdio). Contains `D:\...` and `C:\Users\LENOVO\...` paths. | The image needs Node.js and `uv`. A Linux config is required. OAuth files must be supplied to the container. |
| `C:\Users\LENOVO\.gmail-mcp\` | Holds three files: `gcp-oauth.keys.json`, `token.json`, `credentials.json`. The Sheets MCP is pointed at this folder explicitly (`CREDENTIALS_PATH`, `TOKEN_PATH`); the Gmail MCP has no env override in `mcp_config.json`, so it falls back to its package default, which is the same `~/.gmail-mcp` folder. | All three files need to reach the container's equivalent home folder — see C2 and 5.7. Don't try to work out which server uses which file; mirror the folder as-is. |
| `base_tools.py` | `web_search` (Ollama cloud API) and `get_weather` (WeatherAPI.com). | Needs `OLLAMA_API_KEY` and `WEATHER_API_KEY`. |

**Environment variables the code actually uses**

| Variable | Used by | Required |
|---|---|---|
| `GOOGLE_API_KEY` | Gemini (`langchain-google-genai`) | Yes |
| `OLLAMA_API_KEY` | `web_search` tool | Yes (if you keep the tool) |
| `WEATHER_API_KEY` | `get_weather` tool | Yes (if you keep the tool) |
| `LANGSMITH_API_KEY` | Tracing | Optional |
| `OPENAI_API_KEY` | Not referenced in the files I read | No, do not deploy it |

---

## 2. Target architecture

```text
Browser ──HTTPS──► pa-frontend   Streamlit :8501   (external ingress + Entra ID login)
                        │
                        │  HTTPS, internal to the environment
                        ▼
                   pa-backend    FastAPI :8002     (internal ingress only)
                        │
                        ├─ child processes: npx Gmail MCP, uvx Google Sheets MCP
                        ├─ outbound: Gemini API, Ollama web search, WeatherAPI
                        └─ Azure Files share mounted at /home/appuser/.gmail-mcp (Google OAuth files)

Azure Key Vault ─► Container App secrets ─► environment variables
Azure Container Registry ─► images pulled with a managed identity
Log Analytics ─► container logs
```

Why the backend can be internal-only: the `httpx` call in the Streamlit script runs on the Streamlit server, not in the user's browser. The browser never talks to FastAPI, so FastAPI does not need a public URL.

This matters because the backend has **no authentication** and its tools can read and send your email. It should not be reachable from the internet.

---

## 3. Project changes required

### Must-have

**C1. Make the backend URL configurable (`server/03_streamlit_client.py`)**

```python
# near the top, after the imports
BACKEND_URL = os.getenv("BACKEND_URL", "http://localhost:8002")

# in the request
client.stream("POST", f"{BACKEND_URL}/chat_stream", json={"query": query, "thread_id": thread_id})
```

**C2. Add a Linux MCP config and a switch to select it**

`scripts/utils.py`, one line changes:

```python
config_path = os.getenv("MCP_CONFIG_PATH") or os.path.join(os.path.dirname(__file__), 'mcp_config.json')
```

New file `scripts/mcp_config.container.json` (only the two servers the backend loads):

```json
{
  "gmail": {
    "command": "npx",
    "args": ["-y", "@gongrzhe/server-gmail-autoauth-mcp"],
    "transport": "stdio"
  },
  "google-sheets": {
    "command": "uvx",
    "args": ["--with", "mcp<2", "mcp-google-sheets@latest"],
    "env": {
      "CREDENTIALS_PATH": "/home/appuser/.gmail-mcp/gcp-oauth.keys.json",
      "TOKEN_PATH": "/home/appuser/.gmail-mcp/token.json"
    },
    "transport": "stdio"
  }
}
```

Notes:
- `-y` is added to the `npx` args. Without a terminal, `npx` can stop and wait for a confirmation prompt.
- The original Gmail entry has no paths, so the Gmail MCP uses its default folder `~/.gmail-mcp`. The mount path in this guide (`/home/appuser/.gmail-mcp`) is chosen to match that, since `appuser`'s home is `/home/appuser`.
- Copy all three files from your local `C:\Users\LENOVO\.gmail-mcp\` — `gcp-oauth.keys.json`, `token.json`, `credentials.json` — into that same container path. The Sheets server reads `gcp-oauth.keys.json`/`token.json` because the config says so explicitly; the Gmail server reads whatever it needs from the folder by its own default convention. Moving the whole folder means you don't have to work that mapping out by hand.
- Pin `mcp-google-sheets@latest` and the npm package to specific versions once you have a working build. `@latest` can change under you.

**Adding Google Calendar back later:** the container config above only lists `gmail` and `google-sheets` because that's all `get_tools()` in `02_stream_server.py` requests today (`utils.load_mcp_config("gmail", "google-sheets")`). To bring Calendar back: add a `google-calendar` entry to `mcp_config.container.json` (same shape as the local one, but pointing at the container's OAuth path instead of a Windows path), and add `"google-calendar"` to that `load_mcp_config(...)` call. The `google-calendar-mcp` package needs its own `GOOGLE_OAUTH_CREDENTIALS` file — check whether it can reuse `gcp-oauth.keys.json` or needs a separate authorization, since it's a different npm package from the Gmail one.

**C3. Replace the PDF save with a browser download**

Today the button writes a file into `server/pdf_reports/` on the server. In a container that folder is temporary and invisible to the user. Generate the PDF in memory (`io.BytesIO()` passed to `pisa.CreatePDF`) and offer it with `st.sidebar.download_button(..., mime="application/pdf")`. Render the download button directly rather than inside an `if st.sidebar.button(...)` block, because Streamlit re-runs the script on every click.

**C4. Split and pin the requirements**

The single `requirements.txt` pulls in packages neither app needs (`openai`, `e2b-code-interpreter`, `yfinance`, `pymupdf`, `markitdown[all]`, `pymysql`, and more), which makes the images large and slow to build. Keep `requirements.txt` for local development and add:

`requirements-backend.txt`
```text
python-dotenv
pydantic
fastapi[standard]
langchain
langchain-core
langchain-google-genai
langchain-mcp-adapters
langgraph
ollama
requests
```

`requirements-frontend.txt`
```text
streamlit
httpx
markdown2
xhtml2pdf
```

Pin exact versions from your working environment (`pip freeze` inside `.venv`) before the first build, so the cloud image matches what you tested. The backend uses `from langchain.agents import create_agent`, which needs the current major version of `langchain`.

**C5. Add the Docker files**

`Dockerfile.backend`, `Dockerfile.frontend`, `.dockerignore`, and an optional `docker-compose.yml` for local testing (section 4).

**C6. Do not expose the backend publicly**

Internal ingress for the backend, plus login on the frontend (section 5.11). This is a deployment setting, not a code change.

### Recommended

| # | Change | Why |
|---|---|---|
| R1 | Restrict or remove `allow_origins=["*"]` in the backend CORS setup | The browser never calls the backend, so CORS is not needed at all in this design. |
| R2 | **Decided: keep `InMemorySaver`, run the backend with `minReplicas = maxReplicas = 1`.** (A Postgres checkpointer via `langgraph-checkpoint-postgres` was the alternative — more setup, chat history survives restarts — but that's more than a showcase needs.) | Chat memory is lost on restart and is not shared between replicas. Acceptable here: restarts are infrequent and this isn't a system other people depend on staying up. |
| R3 | Rename `02_stream_server.py` and `03_streamlit_client.py` to names without a leading digit | Optional. The commands below work with the current names. |
| R4 | Add logging and a timeout around MCP tool loading in `lifespan` | If the Google OAuth files are missing, the Gmail MCP server tries to open a browser and the backend start-up can hang. |

---

## 4. Dockerization

### 4.1 `.dockerignore`

Without this, `COPY` could put your `.env` and the 500 MB `.venv` into the image.

```text
.env
.env.*
!.env.example
.venv
.git
.gitignore
__pycache__
*.pyc
*.db
*.db-shm
*.db-wal
vertex-ai.json
server/pdf_reports
.vscode
LICENSE
README.md
```

### 4.2 `Dockerfile.backend`

```dockerfile
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    MCP_CONFIG_PATH=/app/scripts/mcp_config.container.json

# Node.js: the Gmail MCP server is started with npx
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# uv / uvx: the Google Sheets MCP server is started with uvx (pin a tag for reproducible builds)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

RUN useradd --create-home --uid 1000 appuser
WORKDIR /app

COPY requirements-backend.txt .
RUN pip install -r requirements-backend.txt

COPY scripts/ ./scripts/
COPY server/02_stream_server.py ./server/02_stream_server.py

USER appuser
EXPOSE 8002

CMD ["uvicorn", "02_stream_server:app", "--app-dir", "server", "--host", "0.0.0.0", "--port", "8002"]
```

How it runs: `--app-dir server` makes `02_stream_server` importable, and the script itself adds `/app` to `sys.path`, so `from scripts import ...` works unchanged.

### 4.3 `Dockerfile.frontend`

```dockerfile
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    BACKEND_URL=http://localhost:8002

RUN useradd --create-home --uid 1000 appuser
WORKDIR /app

COPY requirements-frontend.txt .
RUN pip install -r requirements-frontend.txt

COPY server/03_streamlit_client.py ./server/03_streamlit_client.py

USER appuser
EXPOSE 8501

CMD ["streamlit", "run", "server/03_streamlit_client.py", \
     "--server.port=8501", "--server.address=0.0.0.0", \
     "--server.headless=true", "--browser.gatherUsageStats=false"]
```

If the `xhtml2pdf` install fails on `pycairo`, add `gcc pkg-config libcairo2-dev` with `apt-get` before `pip install`.

### 4.4 Local test with `docker-compose.yml`

Compose reads `.env` at run time, so the secrets never enter the image. Use Compose rather than `docker run --env-file`, because `docker run` does not strip the quotes in `KEY="value"` lines.

```yaml
services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile.backend
    env_file: .env
    ports:
      - "8002:8002"
    volumes:
      - C:/Users/LENOVO/.gmail-mcp:/home/appuser/.gmail-mcp

  frontend:
    build:
      context: .
      dockerfile: Dockerfile.frontend
    environment:
      BACKEND_URL: http://backend:8002
    ports:
      - "8501:8501"
    depends_on:
      - backend
```

Run `docker compose up --build`, watch the backend log for `Loaded N Tools`, then open http://localhost:8501.

---

## 5. Step-by-step deployment (PowerShell, Azure CLI)

### 5.1 Prerequisites

- An Azure subscription where you can create resources and role assignments.
- Azure CLI, and the Container Apps extension: `az extension add --name containerapp --upgrade`
- The local Docker test from 4.4 works.
- Google OAuth files already created locally (Gmail and Sheets authorised at least once on your PC).

```powershell
az login
az account set --subscription "<subscription-id>"
```

### 5.2 Variables and resource group

Names for the registry, storage account and Key Vault must be globally unique. Adjust them. Set `$LOC` to whichever Azure region you pick — `centralindia` below is a placeholder; every `-l $LOC` and the `location:` line in the backend YAML (5.8) need to match it.

```powershell
$LOC   = "centralindia"   # <- replace with your chosen region
$RG    = "rg-personal-assistant"
$ENVN  = "cae-personal-assistant"
$ACR   = "acrpersonalassistant01"      # letters and digits only
$KV    = "kv-pa-assistant-01"
$SA    = "stpaassistant01"             # lowercase letters and digits, 3-24 chars
$SHARE = "oauth"
$IDN   = "id-personal-assistant"

az group create -n $RG -l $LOC
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.KeyVault
```

### 5.3 Container registry and managed identity

A user-assigned identity is used so its permissions exist before the apps are created.

```powershell
az acr create -n $ACR -g $RG --sku Basic --admin-enabled false

az identity create -g $RG -n $IDN
$IDID        = az identity show -g $RG -n $IDN --query id -o tsv
$IDPRINCIPAL = az identity show -g $RG -n $IDN --query principalId -o tsv
$ACRID       = az acr show -n $ACR --query id -o tsv

az role assignment create --assignee-object-id $IDPRINCIPAL --assignee-principal-type ServicePrincipal --role AcrPull --scope $ACRID
```

### 5.4 Build and push the images (no local Docker needed)

Run from the project root, where the Dockerfiles are.

```powershell
az acr build -r $ACR -t pa-backend:v1  -f Dockerfile.backend  .
az acr build -r $ACR -t pa-frontend:v1 -f Dockerfile.frontend .
```

### 5.5 Container Apps environment

This also creates a Log Analytics workspace for logs.

```powershell
az containerapp env create -n $ENVN -g $RG -l $LOC
$ENVID = az containerapp env show -n $ENVN -g $RG --query id -o tsv
```

### 5.6 Key Vault for API keys

```powershell
az keyvault create -n $KV -g $RG -l $LOC --enable-rbac-authorization true
$KVID = az keyvault show -n $KV --query id -o tsv
$ME   = az ad signed-in-user show --query id -o tsv

az role assignment create --assignee-object-id $ME --assignee-principal-type User --role "Key Vault Secrets Officer" --scope $KVID
az role assignment create --assignee-object-id $IDPRINCIPAL --assignee-principal-type ServicePrincipal --role "Key Vault Secrets User" --scope $KVID
```

Add the secrets. Typing values on the command line stores them in your shell history, so either clear that afterwards or add them in the portal (Key Vault, Secrets, Generate/Import).

```powershell
az keyvault secret set --vault-name $KV --name google-api-key  --value "<GOOGLE_API_KEY>"
az keyvault secret set --vault-name $KV --name ollama-api-key  --value "<OLLAMA_API_KEY>"
az keyvault secret set --vault-name $KV --name weather-api-key --value "<WEATHER_API_KEY>"
```

Role assignments can take a minute or two to take effect.

### 5.7 Azure Files share for the Google OAuth files

The Gmail and Sheets MCP servers refresh their tokens and write them back to disk, so the folder must be writable. A Key Vault secret volume is read-only, so Azure Files is used.

```powershell
az storage account create -n $SA -g $RG -l $LOC --sku Standard_LRS --allow-blob-public-access false --min-tls-version TLS1_2
$SAKEY = az storage account keys list -g $RG -n $SA --query "[0].value" -o tsv

az storage share-rm create --storage-account $SA --resource-group $RG --name $SHARE

# Uploads gcp-oauth.keys.json, token.json and credentials.json from this folder.
az storage file upload-batch --account-name $SA --account-key $SAKEY --destination $SHARE --source "C:\Users\LENOVO\.gmail-mcp"

az containerapp env storage set -n $ENVN -g $RG --storage-name pa-oauth `
  --azure-file-account-name $SA --azure-file-account-key $SAKEY `
  --azure-file-share-name $SHARE --access-mode ReadWrite
```

This share holds credentials that can access your Gmail and Drive. Keep the storage account private and do not share its key.

### 5.8 Deploy the backend (internal ingress, port 8002)

Volumes and Key Vault secret references need a YAML definition. Save this as `backend.yaml`, replacing the `<...>` placeholders with the values from the variables above (`$IDID`, `$ENVID`, `$ACR`, `$KV`).

```yaml
location: centralindia
identity:
  type: UserAssigned
  userAssignedIdentities:
    "<IDID>": {}
properties:
  managedEnvironmentId: "<ENVID>"
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: false
      targetPort: 8002
      transport: auto
    registries:
      - server: "<ACR>.azurecr.io"
        identity: "<IDID>"
    secrets:
      - name: google-api-key
        keyVaultUrl: "https://<KV>.vault.azure.net/secrets/google-api-key"
        identity: "<IDID>"
      - name: ollama-api-key
        keyVaultUrl: "https://<KV>.vault.azure.net/secrets/ollama-api-key"
        identity: "<IDID>"
      - name: weather-api-key
        keyVaultUrl: "https://<KV>.vault.azure.net/secrets/weather-api-key"
        identity: "<IDID>"
  template:
    containers:
      - name: pa-backend
        image: "<ACR>.azurecr.io/pa-backend:v1"
        resources:
          cpu: 1.0
          memory: 2Gi
        env:
          - name: GOOGLE_API_KEY
            secretRef: google-api-key
          - name: OLLAMA_API_KEY
            secretRef: ollama-api-key
          - name: WEATHER_API_KEY
            secretRef: weather-api-key
        volumeMounts:
          - volumeName: oauth
            mountPath: /home/appuser/.gmail-mcp
        probes:
          - type: Startup
            httpGet:
              path: /
              port: 8002
            initialDelaySeconds: 15
            periodSeconds: 15
            failureThreshold: 10
          - type: Liveness
            httpGet:
              path: /
              port: 8002
            periodSeconds: 30
    scale:
      minReplicas: 1
      maxReplicas: 1
    volumes:
      - name: oauth
        storageType: AzureFile
        storageName: pa-oauth
        mountOptions: uid=1000,gid=1000,file_mode=0770,dir_mode=0770
```

```powershell
az containerapp create -n pa-backend -g $RG --yaml backend.yaml
```

The startup probe allows about 2.5 minutes because the app loads its MCP tools before it answers. `GET /` is the existing health endpoint.

### 5.9 Deploy the frontend (external ingress, port 8501)

```powershell
$BACKEND_FQDN = az containerapp show -n pa-backend -g $RG --query properties.configuration.ingress.fqdn -o tsv

az containerapp create -n pa-frontend -g $RG --environment $ENVN `
  --image "$ACR.azurecr.io/pa-frontend:v1" `
  --user-assigned $IDID --registry-server "$ACR.azurecr.io" --registry-identity $IDID `
  --ingress external --target-port 8501 `
  --cpu 0.5 --memory 1.0Gi --min-replicas 1 --max-replicas 1 `
  --env-vars "BACKEND_URL=https://$BACKEND_FQDN"

az containerapp show -n pa-frontend -g $RG --query properties.configuration.ingress.fqdn -o tsv
```

The last command prints the public URL of the UI.

### 5.10 Verify

```powershell
az containerapp logs show -n pa-backend -g $RG --follow
```

Look for `Loaded N Tools` and `Tools are loaded. ready to create agent!`. Then open the frontend URL and try "list my spreadsheets" and "summarise my unread emails".

### 5.11 Lock it down (do this before sharing the URL)

**Decided: Microsoft Entra ID sign-in.** (An IP allow-list was the alternative — one command, but it breaks the moment your public IP changes, and gives no real login page for a showcase you might demo from elsewhere.)

Register an app in Entra ID with the redirect URI `https://<frontend-fqdn>/.auth/login/aad/callback`, then enable built-in authentication:

```powershell
az containerapp auth microsoft update -n pa-frontend -g $RG `
  --client-id "<app-registration-client-id>" --client-secret "<client-secret>" `
  --tenant-id "<tenant-id>" --yes
az containerapp auth update -n pa-frontend -g $RG --enabled true `
  --unauthenticated-client-action RedirectToLoginPage
```

Check the flags with `az containerapp auth update --help`, as they vary between CLI versions. In Entra, set the enterprise application to "Assignment required" and assign only yourself — that's what keeps this a single-user showcase rather than an open sign-up.

Also:
- If the Google OAuth consent screen is in **Testing** status, Google expires refresh tokens after 7 days and the assistant will start failing with `invalid_grant`. Move it to **In production** (your own account can still use it) or plan to re-authenticate weekly.
- The agent can send email through the Gmail tools, and the prompt only asks it to confirm first. Authentication in front of the UI is what protects this.

### 5.12 Updating and operating

```powershell
# new version
az acr build -r $ACR -t pa-backend:v2 -f Dockerfile.backend .
az containerapp update -n pa-backend -g $RG --image "$ACR.azurecr.io/pa-backend:v2"

# after rotating a Key Vault secret, restart so the new value is read
az containerapp revision restart -n pa-backend -g $RG --revision <revision-name>
```

- Cost: both apps run with one replica always on. Setting the frontend to `--min-replicas 0` saves money, but the first visit then waits for a cold start. Keep the backend at 1 because of the slow tool load and in-memory chat state.
- Long answers: the Container Apps ingress closes a request after about 240 seconds, which also cuts a streaming response.
- Logs: Azure portal, Container App, Monitoring, Log stream, or Log Analytics.

### 5.13 Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Backend never becomes ready | The Gmail MCP has no credentials and is waiting for a browser sign-in. Check the files in the Azure Files share and the mount path. |
| `npx: not found` or `uvx: not found` in logs | Node or `uv` missing from the image. Rebuild from the Dockerfile above. |
| Permission error writing tokens | Adjust `mountOptions` (uid/gid) or the account key. Check the container runs as uid 1000. |
| UI shows a connection error | `BACKEND_URL` is wrong, or the backend is not in the same environment. Internal apps are reachable only inside their environment. |
| `invalid_grant` from Google | Token expired or revoked. Re-authorise locally and re-upload the files, then restart the backend. |
| Chat history disappears | Backend restarted (in-memory checkpointer). See R2. |
| Slow tool calls | By default each MCP tool call starts a fresh `npx` or `uvx` process. Pin versions and pre-install the packages in the image to speed this up. |
| Streamlit page stuck on "Please wait" | Check that WebSockets are not blocked by an IP rule. As a last resort add `--server.enableCORS=false --server.enableXsrfProtection=false`. |

---

## 6. Deployment plan

Both columns are things **you** do; "Explain first?" marks the phases worth walking through here before you run them, since they touch billable resources, credentials, or public exposure.

| Phase | Tasks | Output | Explain first? |
|---|---|---|---|
| **0. Decide** | All decisions made — see the banner at the top and section 7 | Nothing pending | — |
| **1. Prepare code** | C1 backend URL variable, C2 Linux MCP config and `utils.py` switch, C3 PDF download, C4 split and pin requirements | Working local app, unchanged behaviour | On request |
| **2. Dockerize** | Add `.dockerignore`, `Dockerfile.backend`, `Dockerfile.frontend`, `docker-compose.yml`; test with `docker compose up --build` | Two images that pass the local Compose test | On request |
| **3. Azure foundation** | Resource group, ACR, managed identity, Key Vault, storage and file share, Container Apps environment (5.2 to 5.7) | Empty but ready infrastructure | Recommended — creates billable resources |
| **4. Deploy** | `az acr build` both images, deploy backend then frontend (5.4, 5.8, 5.9) | Running apps | Recommended — the backend YAML has several moving parts |
| **5. Verify and secure** | Check logs, run test prompts, enable authentication (5.10, 5.11) | Protected, working URL | Recommended — this is what keeps the backend off the open internet |
| **6. Operate** | Tag-based updates, secret rotation, cost review. Optional: GitHub Actions to build and deploy on push | Repeatable releases | Optional |

Checklist:

- [ ] Auth method and chat-memory approach decided
- [ ] Code changes C1 to C4 applied and tested locally
- [ ] Docker files added, `docker compose up` works with Gmail and Sheets answering
- [ ] Azure resources created (in your chosen region)
- [ ] Secrets in Key Vault, all three OAuth files in the file share
- [ ] Backend logs show `Loaded N Tools`
- [ ] Frontend reachable, sign-in enforced
- [ ] Google OAuth consent screen set to In production (or a renewal reminder created)

---

## 7. Decisions recap

This is a showcase deployment, so every trade-off below was resolved toward the simpler option.

| Decision | Choice | Where it's used | Why |
|---|---|---|---|
| Frontend auth | **Entra ID** sign-in, not an IP allow-list | 5.11 | Real login page, survives a changing IP, still a one-person "Assignment required" app |
| Chat memory | **RAM** (`InMemorySaver`), single replica, not Postgres | R2, 5.8 | No extra database to provision or secure; history loss on restart is an acceptable trade for a demo |
| Region | Yours to pick | 5.2, 5.8 (`$LOC` / `location:`) | — |
| OAuth files | `C:\Users\LENOVO\.gmail-mcp` → `gcp-oauth.keys.json`, `token.json`, `credentials.json` | C2, 5.7 | Mirror the whole folder into the container; don't hand-map files to servers |
| MCP servers in the container config | `gmail`, `google-sheets` only | C2 | Yahoo Finance and Airbnb dropped; Google Calendar deferred, with the steps to add it back documented in C2 |

Nothing is open. Section 6's checklist is the thing to work through now.
