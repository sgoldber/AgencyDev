#!/bin/bash
# Rollback agent work to a previous state
# Usage: ./rollback_agent_work.sh <branch-name> [commit-hash|tag-name]

BRANCH_NAME=$1
ROLLBACK_TARGET=${2:-"PRE_AGENT_WORK"}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$BRANCH_NAME" ]; then
    echo "Error: Branch name required"
    echo "Usage: ./rollback_agent_work.sh <branch-name> [commit-hash|tag-name]"
    exit 1
fi

# Source shared functions
source "$(dirname "$0")/lib/common.sh"

echo "Rolling back agent work on branch $BRANCH_NAME to $ROLLBACK_TARGET"

# Check if rollback target exists
cd "$REPO_ROOT/staging"

# Check if it's a tag
if git rev-parse "$ROLLBACK_TARGET" > /dev/null 2>&1; then
    ROLLBACK_COMMIT=$(git rev-parse "$ROLLBACK_TARGET")
    echo "Found rollback target: $ROLLBACK_TARGET ($ROLLBACK_COMMIT)"
else
    echo "Error: Rollback target '$ROLLBACK_TARGET' not found" >&2
    echo "Available tags:" >&2
    git tag -l | grep -E "PRE_AGENT|BACKUP" >&2
    exit 1
fi

# Create backup of current state before rollback
BACKUP_TAG="BACKUP_BEFORE_ROLLBACK_$(date +%Y%m%d_%H%M%S)"
git tag "$BACKUP_TAG" "$BRANCH_NAME"
echo "Created backup tag: $BACKUP_TAG"

# Reset branch to rollback target
git checkout "$BRANCH_NAME"
git reset --hard "$ROLLBACK_COMMIT"

# Force push (use with caution)
echo "Warning: This will force push to remote. Continue? (y/N)"
read -r CONFIRM
if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
    git push origin "$BRANCH_NAME" --force
    echo "Rollback complete. Branch reset to $ROLLBACK_TARGET"
    create_alert "WARNING" "system" "Rollback performed on branch $BRANCH_NAME to $ROLLBACK_TARGET"
    log_event "rollback" "system" "rollback" "Rolled back branch $BRANCH_NAME to $ROLLBACK_TARGET" "$ROLLBACK_COMMIT" 0
else
    echo "Rollback cancelled"
    exit 0
fi
