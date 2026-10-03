"""Phase E, Step 15 — standalone diagnostic.
Confirms Gmail credential refresh and a live API call succeed inside the
container, before trusting the agent-wired path in Step 16.
Run via: docker compose exec backend python scripts/smoke_test_gmail.py
Safe to delete after Phase E passes — this is a diagnostic aid, not app code.
"""
import gmail_tools

gmail_tools.init_gmail()
print("Credentials valid:", gmail_tools._creds.valid)
print("Credentials expiry (UTC):", gmail_tools._creds.expiry)

result = gmail_tools.search_emails.invoke({"query": "is:unread"})
print(f"\nsearch_emails returned {len(result)} message(s):")
for msg in result:
    print(f"  - [{msg['date']}] {msg['from']}: {msg['subject']}")