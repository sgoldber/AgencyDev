#!/bin/bash
# Health check script for agent system
# Usage: ./health-check.sh [agent-name]

AGENT_NAME=${1:-"all"}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source shared functions
source "$(dirname "$0")/lib/common.sh"

echo "Running health check for: $AGENT_NAME"
echo "======================================"

HEALTH_STATUS=0

# Function to check health
check_health() {
    local AGENT=$1
    local STATUS=0
    
    echo ""
    echo "Checking $AGENT..."
    
    # 1. Check worktree access
    BRANCH=$(jq -r '.branch' "$REPO_ROOT/.agent-state/state.json" 2>/dev/null || echo "")
    WORKTREE_DIR=$(find_worktree "$AGENT" "$BRANCH")
    if [ $? -eq 0 ] && [ -d "$WORKTREE_DIR/.git" ]; then
        echo "  ✓ Worktree accessible: $WORKTREE_DIR"
    else
        echo "  ✗ Worktree not accessible"
        STATUS=1
    fi
    
    # 2. Check aider availability
    if command -v aider > /dev/null 2>&1; then
        echo "  ✓ Aider command available"
        
        # Check model availability
        PREFERRED_MODEL=$(jq -r '.aider.model // "gpt-4-turbo-preview"' "$REPO_ROOT/.agent-config.json")
        AVAILABLE_MODEL=$(get_aider_model "$PREFERRED_MODEL" "gpt-4")
        if [ "$AVAILABLE_MODEL" = "$PREFERRED_MODEL" ]; then
            echo "  ✓ Preferred model available: $PREFERRED_MODEL"
        else
            echo "  ⚠ Model fallback: $PREFERRED_MODEL -> $AVAILABLE_MODEL"
        fi
    else
        echo "  ✗ Aider command not found"
        STATUS=1
    fi
    
    # 3. Check state.json update capability
    if update_state "$AGENT" "healthCheck" "$(date +%s)" 2>/dev/null; then
        echo "  ✓ State.json update successful"
        # Clean up test entry
        jq "del(.agents.${AGENT}.healthCheck)" "$REPO_ROOT/.agent-state/state.json" > "$REPO_ROOT/.agent-state/state.json.tmp"
        mv "$REPO_ROOT/.agent-state/state.json.tmp" "$REPO_ROOT/.agent-state/state.json"
    else
        echo "  ✗ State.json update failed"
        STATUS=1
    fi
    
    # 4. Check git push capability (dry run)
    if [ -d "$WORKTREE_DIR" ]; then
        cd "$WORKTREE_DIR"
        if git push --dry-run origin "$(git rev-parse --abbrev-ref HEAD)" > /dev/null 2>&1; then
            echo "  ✓ Git push capability verified"
        else
            echo "  ✗ Git push failed (check permissions)"
            STATUS=1
        fi
        cd "$REPO_ROOT"
    fi
    
    # 5. Check lock file status
    LOCK_FILE="$REPO_ROOT/.agent-state/locks/${AGENT}.lock"
    if [ -f "$LOCK_FILE" ]; then
        check_stale_lock "$LOCK_FILE" 3600
        if [ -f "$LOCK_FILE" ]; then
            echo "  ⚠ Lock file exists (may be active)"
        else
            echo "  ✓ Stale lock cleaned"
        fi
    else
        echo "  ✓ No lock file (agent not running)"
    fi
    
    return $STATUS
}

# Run health checks
if [ "$AGENT_NAME" = "all" ]; then
    for agent in doc-agent test-agent code-review-agent cleanup-agent; do
        if ! check_health "$agent"; then
            HEALTH_STATUS=1
        fi
    done
else
    if ! check_health "$AGENT_NAME"; then
        HEALTH_STATUS=1
    fi
fi

echo ""
echo "======================================"
if [ $HEALTH_STATUS -eq 0 ]; then
    echo "Health check: PASSED"
    exit 0
else
    echo "Health check: FAILED"
    create_alert "WARNING" "system" "Health check failed for agent(s)"
    exit 1
fi
