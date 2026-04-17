#!/bin/bash
# Cleanup Agent Runner - Squashes agent commits into clean history

AGENT_NAME="cleanup-agent"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_ROOT/.agent-state/state.json"
LOCK_FILE="$REPO_ROOT/.agent-state/locks/${AGENT_NAME}.lock"

# Source shared functions
source "$(dirname "$0")/lib/common.sh"

# Validate configuration
if ! validate_config; then
    echo "Error: Configuration validation failed" >&2
    exit 1
fi

# Get available aider model with fallback
PREFERRED_MODEL=$(jq -r '.aider.model // "gpt-4-turbo-preview"' "$REPO_ROOT/.agent-config.json")
AIDER_MODEL=$(get_aider_model "$PREFERRED_MODEL" "gpt-4")
# For cleanup agent, prefer o3-mini for reasoning, but fallback to configured model
CLEANUP_MODEL=$(get_aider_model "o3-mini" "$AIDER_MODEL")

BRANCH=$(jq -r ".branch" "$STATE_FILE")
AGENT_BRANCH=$(get_agent_branch "$BRANCH" "$AGENT_NAME")

# Get agent branch names for merging
DOC_BRANCH=$(get_agent_branch "$BRANCH" "doc-agent")
TEST_BRANCH=$(get_agent_branch "$BRANCH" "test-agent")
REVIEW_BRANCH=$(get_agent_branch "$BRANCH" "code-review-agent")

# Find worktree directory using shared function
WORKTREE_DIR=$(find_worktree "$AGENT_NAME" "$BRANCH")
if [ $? -ne 0 ] || [ -z "$WORKTREE_DIR" ]; then
    echo "Worktree not found, waiting for vibe-kanban to create it..."
    log_event "warning" "$AGENT_NAME" "worktree_not_found" "Worktree not found for $AGENT_NAME on branch $BRANCH" "" 0
    sleep 5
    exit 0
fi

cd "$WORKTREE_DIR"
log_event "info" "$AGENT_NAME" "worktree_found" "Using worktree: $WORKTREE_DIR" "" 0

# Wait for all other agents to finish
while [ -f "$REPO_ROOT/.agent-state/locks/doc-agent.lock" ] || \
      [ -f "$REPO_ROOT/.agent-state/locks/test-agent.lock" ] || \
      [ -f "$REPO_ROOT/.agent-state/locks/code-review-agent.lock" ]; do
    echo "Waiting for other agents to finish..."
    sleep 10
done

# Check for stale lock
check_stale_lock "$LOCK_FILE" 3600

# Acquire lock
if [ -f "$LOCK_FILE" ]; then
    echo "Lock exists, waiting..."
    log_event "warning" "$AGENT_NAME" "lock_wait" "Lock file exists, another instance may be running" "" 0
    sleep 10
    exit 1
fi
touch "$LOCK_FILE"
log_event "info" "$AGENT_NAME" "lock_acquired" "Lock acquired successfully" "" 0

# API Quota Protection
if ! "$REPO_ROOT/scripts/check-api-quota.sh"; then
    echo "API quota exceeded, exiting" >&2
    create_alert "CRITICAL" "$AGENT_NAME" "API cost limit exceeded - circuit breaker activated"
    rm "$LOCK_FILE"
    exit 1
fi

# PRE-FLIGHT PULL: Fetch all agent branches and main branch
echo "Pre-flight: Fetching all agent branches..."
git fetch origin "$BRANCH" || {
    rm "$LOCK_FILE"
    exit 1
}
git fetch origin "$DOC_BRANCH" 2>/dev/null || true
git fetch origin "$TEST_BRANCH" 2>/dev/null || true
git fetch origin "$REVIEW_BRANCH" 2>/dev/null || true
git fetch origin "$AGENT_BRANCH" 2>/dev/null || true

# Checkout cleanup branch
git checkout "$AGENT_BRANCH" || {
    echo "Error: Failed to checkout cleanup branch $AGENT_BRANCH" >&2
    rm "$LOCK_FILE"
    exit 1
}

# Merge all three agent branches into cleanup branch
echo "Merging agent branches into cleanup branch..."
git merge origin/"$DOC_BRANCH" --no-edit || {
    echo "Warning: Merge conflict or error merging $DOC_BRANCH into $AGENT_BRANCH" >&2
}
git merge origin/"$TEST_BRANCH" --no-edit || {
    echo "Warning: Merge conflict or error merging $TEST_BRANCH into $AGENT_BRANCH" >&2
}
git merge origin/"$REVIEW_BRANCH" --no-edit || {
    echo "Warning: Merge conflict or error merging $REVIEW_BRANCH into $AGENT_BRANCH" >&2
}

# PRE-FLIGHT DEPENDENCY SYNC
echo "Pre-flight: Checking and syncing dependencies..."
sync_dependencies "$WORKTREE_DIR" "$AGENT_NAME"

# Identify agent commits to squash (from all merged agent branches)
# Count commits from agent branches that aren't in main
AGENT_COMMITS=$(git log --oneline origin/main..HEAD | grep -E "^(docs|test|review):" | wc -l)

if [ "$AGENT_COMMITS" -eq 0 ]; then
    echo "No agent commits to clean up"
    rm "$LOCK_FILE"
    exit 0
fi

# NON-INTERACTIVE SQUASH: Use git reset --soft instead of interactive rebase
echo "Squashing agent commits using non-interactive method..."

# CRITICAL: Capture commit information BEFORE reset
OLD_HEAD=$(git rev-parse HEAD)

# Capture commit messages and details before reset
AGENT_COMMIT_MESSAGES=$(git log --oneline origin/main..HEAD | grep -E "^(docs|test|review):")
AGENT_COMMIT_DETAILS=$(git log origin/main..HEAD --format="%h %s%n%b" | grep -A 10 -E "^(docs|test|review):" || git log --oneline origin/main..HEAD | grep -E "^(docs|test|review):")

# Get the base commit (last commit before agent commits)
BASE_COMMIT=$(git merge-base origin/main HEAD)

# Reset to base but keep all changes staged
git reset --soft "$BASE_COMMIT"

# Generate a comprehensive commit message using aider
AIDER_PROMPT="You are a cleanup agent. Review the following agent commits and generate a single, comprehensive commit message that summarizes all the work:

Agent commits being squashed:
$AGENT_COMMIT_DETAILS

Create a commit message that:
- Summarizes the feature development
- Mentions documentation, tests, and code review work
- Is clear and human-readable
- Follows conventional commit format

Output ONLY the commit message, no other text."

# Get commit message from aider (using reasoning model for better analysis)
COMMIT_MSG=$(aider --model "$CLEANUP_MODEL" \
      --yes-always \
      --map-tokens 1024 \
      --message "$AIDER_PROMPT" \
      --no-commit \
      /dev/null 2>/dev/null | grep -v "^#" | head -20)

# Track actual API costs
track_api_cost "$CLEANUP_MODEL"

# If aider didn't generate a message, use a default
if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="feat: Comprehensive feature update with documentation, tests, and code review"
fi

# Create the squashed commit on cleanup branch
git commit -m "$COMMIT_MSG"

echo "Agent commits squashed into single commit: $(git rev-parse --short HEAD)"

# Merge cleanup branch back into main branch
echo "Merging cleanup branch back into main branch..."
git checkout "$BRANCH" || {
    echo "Error: Failed to checkout main branch $BRANCH" >&2
    rm "$LOCK_FILE"
    exit 1
}
git merge "$AGENT_BRANCH" --no-edit || {
    echo "Warning: Merge conflict or error merging $AGENT_BRANCH into $BRANCH" >&2
    # Continue anyway - might need manual resolution
}

# Push the squashed commit to main branch
if ! retry_git_push "$BRANCH" 5; then
    echo "Error: Failed to push main branch $BRANCH after multiple attempts. Manual intervention required." >&2
    log_event "error" "$AGENT_NAME" "push_failed" "Failed to push $BRANCH after 5 attempts" "$(git rev-parse HEAD)" 0
    rm "$LOCK_FILE"
    exit 1
fi

# After successful push, get the commit hash
ACTUAL_COMMIT=$(git rev-parse HEAD)

# Update state using shared function
update_state "$AGENT_NAME" "lastProcessedCommit" "$ACTUAL_COMMIT"

# Update vibe-kanban
"$REPO_ROOT/scripts/vibe-kanban-sync.sh" "$AGENT_NAME" "done" "$ACTUAL_COMMIT"

# Release lock and log operation completion
log_operation_end "$AGENT_NAME" "agent_run" "success" "Agent run completed successfully" "$ACTUAL_COMMIT"
rm "$LOCK_FILE"
