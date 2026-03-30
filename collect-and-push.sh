#!/bin/bash
# collect-and-push.sh — Собирает данные токенов из OpenClaw и пушит в GitHub
# Запускать на сервере по крону: */60 * * * * /home/openclaw/token-analytics/collect-and-push.sh

set -euo pipefail

REPO_DIR="/home/openclaw/token-analytics"
DATA_DIR="$REPO_DIR/data"
HISTORY_FILE="$DATA_DIR/requests-history.json"
LOG="/tmp/openclaw/collect-push.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG"; }

log "=== Starting collection ==="

mkdir -p "$DATA_DIR"

# --- Step 1: Collect session data from openclaw status --json ---
STATUS_JSON=$(openclaw status --json 2>/dev/null || echo '{}')

python3 - "$DATA_DIR" "$HISTORY_FILE" << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone

DATA_DIR = sys.argv[1]
HISTORY_FILE = sys.argv[2]

# Read status JSON from stdin
status_raw = os.popen("openclaw status --json 2>/dev/null").read()
try:
    status = json.loads(status_raw)
except json.JSONDecodeError:
    print("[collect] ERROR: Failed to parse openclaw status --json")
    sys.exit(1)

now = datetime.now(timezone.utc)
now_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")
today = now.strftime("%Y-%m-%d")

# --- Extract ALL sessions from byAgent (not just recent 10) ---
sessions_data = status.get("sessions", {})
by_agent = sessions_data.get("byAgent", [])

# Collect all sessions from all agent blocks
all_sessions = []
for agent_block in by_agent:
    for s in agent_block.get("recent", []):
        all_sessions.append(s)

# Fallback to top-level recent if byAgent is empty
if not all_sessions:
    all_sessions = sessions_data.get("recent", [])

print(f"[collect] Found {len(all_sessions)} total sessions across {len(by_agent)} agents")

# Build status.json (for Status tab)
gateway_info = status.get("gatewayService", {})
gw_status = "running" if gateway_info.get("state") == "active" else "unknown"
# Fallback: check gateway key
if gw_status == "unknown":
    gw = status.get("gateway", {})
    if isinstance(gw, dict) and "reachable" in str(gw):
        gw_status = "running"

# Deduplicate sessions by sessionId
seen_ids = set()
unique_sessions = []
for s in all_sessions:
    sid = s.get("sessionId", "")
    if sid in seen_ids:
        continue
    seen_ids.add(sid)
    unique_sessions.append(s)

status_out = {
    "updated_at": now_str,
    "gateway": gw_status,
    "sessions": []
}
for s in unique_sessions:
    status_out["sessions"].append({
        "agent": s.get("agentId", "unknown"),
        "model": s.get("model", "unknown"),
        "tokens_used": s.get("totalTokens", 0),
        "context_window": s.get("contextTokens", 0),
        "last_active": f"{s.get('age', 0) // 1000}s ago",
        "input_tokens": s.get("inputTokens", 0),
        "output_tokens": s.get("outputTokens", 0),
        "cache_read": s.get("cacheRead", 0)
    })

with open(os.path.join(DATA_DIR, "status.json"), "w") as f:
    json.dump(status_out, f, indent=2, ensure_ascii=False)
print(f"[collect] Wrote status.json with {len(status_out['sessions'])} sessions")

# --- Build requests.json from sessions ---
# Each session becomes a "request" entry for the webapp
# Also load history to accumulate over time
history = []
if os.path.exists(HISTORY_FILE):
    try:
        with open(HISTORY_FILE) as f:
            history = json.load(f)
    except:
        history = []

# Track which session IDs we've already recorded
known_sids = {r.get("session_id") for r in history if r.get("session_id")}

new_count = 0
for s in unique_sessions:
    sid = s.get("sessionId", "")
    if sid in known_sids:
        # Update existing entry with latest token counts
        for h in history:
            if h.get("session_id") == sid:
                h["input_tokens"] = s.get("inputTokens", 0)
                h["output_tokens"] = s.get("outputTokens", 0)
                h["cache_read"] = s.get("cacheRead", 0)
                break
        continue

    # Determine timestamp from updatedAt (epoch ms)
    updated_at = s.get("updatedAt", 0)
    if updated_at > 0:
        ts = datetime.fromtimestamp(updated_at / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    else:
        ts = now_str

    # Determine provider from model name
    model = s.get("model", "unknown")
    if "gemini" in model:
        provider = "google"
    elif "gpt" in model or "codex" in model:
        provider = "openai-codex"
    elif "claude" in model:
        provider = "anthropic"
    else:
        provider = "unknown"

    # Determine source from session key
    key = s.get("key", "")
    skill = None
    if ":cron:" in key:
        skill = "cron"
    elif ":telegram:" in key:
        skill = "telegram"

    history.append({
        "id": f"req_{len(history)+1:04d}",
        "session_id": sid,
        "timestamp": ts,
        "agent": s.get("agentId", "unknown"),
        "model": f"{provider}/{model}",
        "skill": skill,
        "input_tokens": s.get("inputTokens", 0),
        "output_tokens": s.get("outputTokens", 0),
        "cache_read": s.get("cacheRead", 0),
        "provider": provider
    })
    new_count += 1

# Sort by timestamp
history.sort(key=lambda x: x.get("timestamp", ""))

# Re-number
for i, req in enumerate(history, 1):
    req["id"] = f"req_{i:04d}"

# Save history (cumulative)
with open(HISTORY_FILE, "w") as f:
    json.dump(history, f, indent=2, ensure_ascii=False)

# Save requests.json (what the webapp reads)
# Strip session_id from output (internal field)
webapp_data = []
for h in history:
    entry = {k: v for k, v in h.items() if k != "session_id"}
    webapp_data.append(entry)

with open(os.path.join(DATA_DIR, "requests.json"), "w") as f:
    json.dump(webapp_data, f, indent=2, ensure_ascii=False)

print(f"[collect] Wrote requests.json: {len(webapp_data)} total entries ({new_count} new)")
PYEOF

# --- Step 2: Push to GitHub ---
cd "$REPO_DIR"

# Check if there are changes
if git diff --quiet data/ 2>/dev/null; then
    log "No changes to push"
    echo "[collect] No changes detected, skipping push"
else
    git add data/requests.json data/status.json data/requests-history.json
    git commit -m "auto: update token data $(date -u +%Y-%m-%dT%H:%M:%SZ)" --no-gpg-sign 2>/dev/null || true
    git push origin main 2>/dev/null
    log "Pushed updates to GitHub"
    echo "[collect] Pushed to GitHub"
fi

log "=== Done ==="
