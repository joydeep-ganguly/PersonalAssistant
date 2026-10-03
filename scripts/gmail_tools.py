"""Python-based Gmail tools, replacing the Node.js Gmail MCP server.

Built on google-auth / google-api-python-client — the same HTTP stack
already confirmed to complete OAuth token refreshes cleanly inside the
container (see Gmail_Tool_Replacement_Plan.md for the diagnosis).
"""

import os
import json
import base64
from email.mime.text import MIMEText

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from langchain.tools import tool

GMAIL_OAUTH_KEYS = os.getenv("GMAIL_OAUTH_KEYS_PATH", "/home/appuser/.gmail-mcp/gcp-oauth.keys.json")
GMAIL_TOKEN_PATH = os.getenv("GMAIL_TOKEN_PATH", "/home/appuser/.gmail-mcp/credentials.json")

_creds = None
_service = None


def load_gmail_credentials() -> Credentials:
    with open(GMAIL_OAUTH_KEYS) as f:
        keys = json.load(f)["installed"]
    with open(GMAIL_TOKEN_PATH) as f:
        token = json.load(f)

    creds = Credentials(
        token=token.get("access_token"),
        refresh_token=token["refresh_token"],
        token_uri=keys["token_uri"],
        client_id=keys["client_id"],
        client_secret=keys["client_secret"],
        scopes=token.get("scope", "").split(),
    )
    creds.refresh(Request())
    return creds


def init_gmail():
    """Call once at startup (from get_tools()/lifespan)."""
    global _creds, _service
    _creds = load_gmail_credentials()
    _service = build("gmail", "v1", credentials=_creds)


def _extract_body(payload) -> str:
    """Walk a Gmail message payload and return the best available text body."""
    if payload.get("mimeType") == "text/plain" and payload.get("body", {}).get("data"):
        return base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8", errors="replace")

    if payload.get("parts"):
        for part in payload["parts"]:
            if part.get("mimeType") == "text/plain" and part.get("body", {}).get("data"):
                return base64.urlsafe_b64decode(part["body"]["data"]).decode("utf-8", errors="replace")
        for part in payload["parts"]:
            text = _extract_body(part)
            if text:
                return text

    if payload.get("body", {}).get("data"):
        return base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8", errors="replace")

    return ""


@tool
def search_emails(query: str):
    """Search Gmail using Gmail search syntax (e.g. 'is:unread', 'from:x@y.com').
    Returns matching messages with id, snippet, subject, sender and date."""
    results = _service.users().messages().list(userId="me", q=query, maxResults=10).execute()
    msgs = results.get("messages", [])
    enriched = []
    for m in msgs:
        full = _service.users().messages().get(
            userId="me", id=m["id"], format="metadata",
            metadataHeaders=["Subject", "From", "Date"]
        ).execute()
        headers = {h["name"]: h["value"] for h in full["payload"]["headers"]}
        enriched.append({
            "id": m["id"],
            "snippet": full.get("snippet", ""),
            "subject": headers.get("Subject", ""),
            "from": headers.get("From", ""),
            "date": headers.get("Date", ""),
        })
    return enriched


@tool
def read_email(message_id: str):
    """Read the full content of a single email by its message id (from search_emails)."""
    msg = _service.users().messages().get(userId="me", id=message_id, format="full").execute()
    body = _extract_body(msg["payload"])
    headers = {h["name"]: h["value"] for h in msg["payload"]["headers"]}
    return {
        "id": message_id,
        "subject": headers.get("Subject", ""),
        "from": headers.get("From", ""),
        "date": headers.get("Date", ""),
        "body": body,
    }


@tool
def create_draft(to: str, subject: str, body: str):
    """Create a Gmail draft. Never sends — the user must send it manually or confirm elsewhere."""
    message = MIMEText(body)
    message["to"] = to
    message["subject"] = subject
    raw = base64.urlsafe_b64encode(message.as_bytes()).decode()
    draft = _service.users().drafts().create(
        userId="me", body={"message": {"raw": raw}}
    ).execute()
    return {"draft_id": draft["id"], "to": to, "subject": subject}