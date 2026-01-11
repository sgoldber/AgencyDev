#!/bin/bash
# Usage: ./end_feature.sh <branch-name>

BRANCH_NAME=$1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$BRANCH_NAME" ]; then
    echo "Error: Branch name required"
    exit 1
fi

# Remove worktrees
cd "$REPO_ROOT"
git worktree remove doc-agent --force 2>/dev/null || true
git worktree remove test-agent --force 2>/dev/null || true
git worktree remove code-review-agent --force 2>/dev/null || true
git worktree remove cleanup-agent --force 2>/dev/null || true

# Clean up vibe-kanban (optional)
# npx vibe-kanban delete-project --project "$BRANCH_NAME-development"

# Remove cron jobs for this feature
echo "Removing cron jobs..."
crontab -l 2>/dev/null | grep -v "agent-runner.sh" | grep -v "check-feedback.sh" | crontab - 2>/dev/null || true
echo "Cron jobs removed"

echo "Feature branch $BRANCH_NAME cleaned up"
