#!/bin/bash
# Minimal sync script - vibe-kanban handles most tracking automatically

AGENT_NAME=$1
STATUS=$2
COMMIT_HASH=$3
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Only sync if vibe-kanban MCP server is available
# Otherwise, vibe-kanban's native monitoring handles task tracking
if command -v vibe-kanban-mcp &> /dev/null; then
    # Use MCP server for programmatic updates
    vibe-kanban-mcp update-task \
      --board "$AGENT_NAME" \
      --task-id "task-${COMMIT_HASH}" \
      --status "$STATUS"
fi

# Log update
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Agent status: $AGENT_NAME -> $STATUS (commit: $COMMIT_HASH)" \
  >> "$REPO_ROOT/.agent-state/logs/vibe-kanban-sync.log"
