#!/bin/bash
# Test Agent Runner using aider

AGENT_NAME="test-agent"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_ROOT/.agent-state/state.json"
LOCK_FILE="$REPO_ROOT/.agent-state/locks/${AGENT_NAME}.lock"

# Source shared functions
source "$(dirname "$0")/lib/common.sh"

TEST_CMD=$(jq -r '.testCommand' "$REPO_ROOT/.agent-config.json")
BRANCH=$(jq -r ".branch" "$STATE_FILE")
AGENT_BRANCH=$(get_agent_branch "$BRANCH" "$AGENT_NAME")

# Find worktree directory using shared function
WORKTREE_DIR=$(find_worktree "$AGENT_NAME" "$BRANCH")
if [ $? -ne 0 ] || [ -z "$WORKTREE_DIR" ]; then
    echo "Worktree not found, waiting for vibe-kanban to create it..."
    sleep 5
    exit 0
fi

cd "$WORKTREE_DIR"

# Agents run in parallel - no need to wait for doc-agent

# Check for refinement requests (developer feedback)
FEEDBACK_DIR="$REPO_ROOT/.agent-state/feedback"
mkdir -p "$FEEDBACK_DIR"
PENDING_REFINEMENT=$(find "$FEEDBACK_DIR" -name "${AGENT_NAME}-*.json" -type f ! -name "*-refinements.json" 2>/dev/null | \
    xargs jq -r 'select(.processed == false and .agentName == "'"$AGENT_NAME"'") | .refinementId' 2>/dev/null | head -1)

if [ -n "$PENDING_REFINEMENT" ] && [ "$PENDING_REFINEMENT" != "null" ]; then
    REFINEMENT_FILE="$FEEDBACK_DIR/${PENDING_REFINEMENT}.json"
    if [ -f "$REFINEMENT_FILE" ]; then
        REFINEMENT_FEEDBACK=$(jq -r '.feedback' "$REFINEMENT_FILE")
        REFINEMENT_ITERATION=$(jq -r '.iteration' "$REFINEMENT_FILE")
        REFINEMENT_COMMIT=$(jq -r '.commitHash' "$REFINEMENT_FILE")
        
        MAX_ITERATIONS=3
        if [ "$REFINEMENT_ITERATION" -gt "$MAX_ITERATIONS" ]; then
            echo "Refinement iteration limit ($MAX_ITERATIONS) exceeded. Marking as needs manual review."
            jq '.processed = true | .status = "max_iterations_exceeded"' "$REFINEMENT_FILE" > "$REFINEMENT_FILE.tmp"
            mv "$REFINEMENT_FILE.tmp" "$REFINEMENT_FILE"
            exit 0
        fi
        
        REFINEMENT_MODE=true
        echo "Refinement mode: Processing feedback for commit $REFINEMENT_COMMIT (iteration $REFINEMENT_ITERATION)"
    else
        REFINEMENT_MODE=false
    fi
else
    REFINEMENT_MODE=false
fi

# Check for stale lock and clean if needed
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

# PRE-FLIGHT PULL
echo "Pre-flight: Syncing worktree with remote..."
# Fetch both main branch and agent branch
git fetch origin "$BRANCH" || {
    rm "$LOCK_FILE"
    exit 1
}
git fetch origin "$AGENT_BRANCH" 2>/dev/null || true

# Checkout agent branch and merge main branch into it
git checkout "$AGENT_BRANCH" || {
    echo "Error: Failed to checkout agent branch $AGENT_BRANCH" >&2
    rm "$LOCK_FILE"
    exit 1
}

# Merge main branch into agent branch to get latest changes
git merge origin/"$BRANCH" --no-edit || {
    echo "Warning: Merge conflict or error merging $BRANCH into $AGENT_BRANCH" >&2
    # Continue anyway - might be first run
}

# Handle refinement mode vs normal mode
if [ "$REFINEMENT_MODE" = true ]; then
    if ! git cat-file -e "$REFINEMENT_COMMIT" 2>/dev/null; then
        echo "Error: Refinement commit $REFINEMENT_COMMIT does not exist in repository" >&2
        log_event "error" "$AGENT_NAME" "refinement_invalid" "Refinement commit not found: $REFINEMENT_COMMIT" "" 0
        rm "$LOCK_FILE"
        exit 1
    fi
    
    echo "Refinement mode: Checking out commit $REFINEMENT_COMMIT"
    # In refinement mode, checkout the specific commit (might be in detached HEAD)
    git checkout "$REFINEMENT_COMMIT" || {
        echo "Error: Could not checkout refinement commit $REFINEMENT_COMMIT" >&2
        log_event "error" "$AGENT_NAME" "refinement_checkout_failed" "Failed to checkout refinement commit" "$REFINEMENT_COMMIT" 0
        rm "$LOCK_FILE"
        exit 1
    }
    
    CHANGED_SOURCE_FILES=$(git diff --name-only "$REFINEMENT_COMMIT^..$REFINEMENT_COMMIT" 2>/dev/null | grep -v -E "(test/|spec/|__tests__|\.test\.|\.spec\.)")
    LATEST_COMMIT="$REFINEMENT_COMMIT"
    
    AIDER_PROMPT="You are a test agent. You previously wrote tests for this code, but the developer has provided feedback requesting changes.

DEVELOPER FEEDBACK:
$REFINEMENT_FEEDBACK

Please redo your test writing with the following in mind:
- Address the specific feedback provided above
- Create test files if they don't exist
- Write unit tests for new/modified functions
- Write integration tests if applicable
- Ensure edge cases are covered
- Follow project's test patterns

This is refinement iteration $REFINEMENT_ITERATION. Please ensure your tests address the developer's concerns."
    
    TEST_FILES=$(find test/ spec/ -type f 2>/dev/null | head -20)
    if [ -z "$TEST_FILES" ]; then
        TEST_FILES="test/"
    fi
else
    # Normal mode: ensure we're on agent branch (already done above, but verify)
    git checkout "$AGENT_BRANCH" || {
        echo "Error: Failed to checkout agent branch $AGENT_BRANCH" >&2
        rm "$LOCK_FILE"
        exit 1
    }
    
    echo "Pre-flight: Checking and syncing dependencies..."
    sync_dependencies "$WORKTREE_DIR" "$AGENT_NAME"
    
    # Get latest commit from main branch (what we're monitoring)
    LATEST_COMMIT=$(git rev-parse origin/"$BRANCH")
    
    LAST_COMMIT=$(jq -r ".agents.${AGENT_NAME}.lastProcessedCommit" "$STATE_FILE")
    if [ -z "$LAST_COMMIT" ] || [ "$LAST_COMMIT" = "null" ] || [ "$LAST_COMMIT" = "" ]; then
        NEW_COMMITS=$(git log --oneline origin/main..origin/"$BRANCH" 2>/dev/null | wc -l)
    else
        NEW_COMMITS=$(git log --oneline "$LAST_COMMIT"..origin/"$BRANCH" 2>/dev/null | wc -l)
    fi
    
    if [ "$NEW_COMMITS" -eq 0 ]; then
        echo "No new commits to process"
        rm "$LOCK_FILE"
        exit 0
    fi
    
    CHANGED_SOURCE_FILES=$(get_changed_files "$LAST_COMMIT" "$BRANCH" "source")
    
    AIDER_PROMPT="You are a test agent. Write comprehensive tests for recently changed source files:
- Create test files if they don't exist
- Write unit tests for new/modified functions
- Write integration tests if applicable
- Ensure edge cases are covered
- Follow project's test patterns"
    
    TEST_FILES="test/"
fi

# Get available aider model
PREFERRED_MODEL=$(jq -r '.aider.model // "gpt-4-turbo-preview"' "$REPO_ROOT/.agent-config.json")
AIDER_MODEL=$(get_aider_model "$PREFERRED_MODEL" "gpt-4")

COMMIT_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")

# Run aider
aider --model "$AIDER_MODEL" \
      --yes-always \
      --commit \
      --map-tokens 1024 \
      --message "$AIDER_PROMPT" \
      $TEST_FILES

track_api_cost "$AIDER_MODEL"

COMMIT_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ "$COMMIT_BEFORE" = "$COMMIT_AFTER" ] && [ -n "$COMMIT_BEFORE" ] && [ "$REFINEMENT_MODE" = true ]; then
    echo "Warning: Aider did not create a new commit during refinement."
    rm "$LOCK_FILE"
    exit 1
fi

# Run tests
eval "$TEST_CMD"
TEST_EXIT=$?

# If tests fail, use aider to fix them
RETRY_COUNT=0
if [ $TEST_EXIT -ne 0 ]; then
    AIDER_PROMPT="The tests are failing. Analyze the failure messages and fix the test code (not the source code). Ensure all tests pass."
    
    for i in {1..5}; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log_event "retry" "$AGENT_NAME" "test_fix" "Attempt $RETRY_COUNT/5 to fix failing tests" "$LATEST_COMMIT" 0
        
        aider --model "$AIDER_MODEL" \
              --yes-always \
              --commit \
              --map-tokens 1024 \
              --message "$AIDER_PROMPT" \
              test/
        
        track_api_cost "$AIDER_MODEL"
        
        eval "$TEST_CMD"
        if [ $? -eq 0 ]; then
            log_event "success" "$AGENT_NAME" "test_fix" "Tests fixed after $RETRY_COUNT attempts" "$LATEST_COMMIT" 0
            break
        fi
    done
    
    if [ "$RETRY_COUNT" -gt 1 ]; then
        echo "Warning: Test agent required $RETRY_COUNT attempts to fix tests" >&2
        log_event "warning" "$AGENT_NAME" "test_retries" "Test agent required $RETRY_COUNT attempts" "$LATEST_COMMIT" 0
    fi
fi

# RETRY-ON-PUSH-FAIL
# Push to agent branch, not main branch
if ! retry_git_push "$AGENT_BRANCH" 5; then
    echo "Error: Failed to push to agent branch $AGENT_BRANCH after multiple attempts. Manual intervention required." >&2
    log_event "error" "$AGENT_NAME" "push_failed" "Failed to push to $AGENT_BRANCH after 5 attempts" "$ACTUAL_COMMIT" 0
    rm "$LOCK_FILE"
    exit 1
fi

ACTUAL_COMMIT=$(git rev-parse HEAD)

update_state "$AGENT_NAME" "lastProcessedCommit" "$ACTUAL_COMMIT"

# Handle refinement completion
if [ "$REFINEMENT_MODE" = true ]; then
    jq ".processed = true | .status = \"completed\" | .iteration = $((REFINEMENT_ITERATION + 1))" \
       "$REFINEMENT_FILE" > "$REFINEMENT_FILE.tmp"
    mv "$REFINEMENT_FILE.tmp" "$REFINEMENT_FILE"
    
    "$REPO_ROOT/scripts/vibe-kanban-sync.sh" "$AGENT_NAME" "in_progress" "$ACTUAL_COMMIT"
    echo "Refinement completed: processed commit $REFINEMENT_COMMIT, created new commit $ACTUAL_COMMIT"
else
    "$REPO_ROOT/scripts/vibe-kanban-sync.sh" "$AGENT_NAME" "done" "$ACTUAL_COMMIT"
fi

log_operation_end "$AGENT_NAME" "agent_run" "success" "Agent run completed successfully" "$ACTUAL_COMMIT"
rm "$LOCK_FILE"
