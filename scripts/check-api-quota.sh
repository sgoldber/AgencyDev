#!/bin/bash
# Circuit breaker for API quota protection (Issue #15 - Alerting)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COST_FILE="$REPO_ROOT/.agent-state/metrics/daily_cost.json"
CONFIG_FILE="$REPO_ROOT/.agent-config.json"

# Source shared functions for alerting
source "$(dirname "$0")/lib/common.sh"

# Initialize cost file if it doesn't exist
if [ ! -f "$COST_FILE" ]; then
    cat > "$COST_FILE" <<EOF
{
  "date": "$(date +%Y-%m-%d)",
  "totalCostUSD": 0.0,
  "lastReset": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
fi

# Check if we need to reset (new day)
CURRENT_DATE=$(date +%Y-%m-%d)
STORED_DATE=$(jq -r '.date' "$COST_FILE")

if [ "$CURRENT_DATE" != "$STORED_DATE" ]; then
    # Reset for new day
    cat > "$COST_FILE" <<EOF
{
  "date": "$CURRENT_DATE",
  "totalCostUSD": 0.0,
  "lastReset": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    # Clear critical alert flag on new day
    rm -f "$REPO_ROOT/.agent-state/alerts/CRITICAL.flag"
fi

# Read limits from config
DAILY_LIMIT=$(jq -r '.costLimits.dailyLimitUSD' "$CONFIG_FILE")
ALERT_THRESHOLD=$(jq -r '.costLimits.alertThresholdUSD' "$CONFIG_FILE")
CURRENT_COST=$(jq -r '.totalCostUSD' "$COST_FILE")

# Check if limit exceeded
if (( $(echo "$CURRENT_COST >= $DAILY_LIMIT" | bc -l) )); then
    echo "ERROR: Daily API cost limit exceeded: \$$CURRENT_COST >= \$$DAILY_LIMIT" >&2
    echo "Circuit breaker activated. Agent execution halted." >&2
    echo "Update $COST_FILE to reset or increase limit in $CONFIG_FILE" >&2
    create_alert "CRITICAL" "system" "API cost limit exceeded: \$$CURRENT_COST >= \$$DAILY_LIMIT"
    exit 1
fi

# Check if alert threshold reached
if (( $(echo "$CURRENT_COST >= $ALERT_THRESHOLD" | bc -l) )); then
    echo "WARNING: Approaching daily cost limit: \$$CURRENT_COST / \$$DAILY_LIMIT" >&2
    create_alert "WARNING" "system" "Cost threshold reached: \$$CURRENT_COST / \$$DAILY_LIMIT"
fi

exit 0
