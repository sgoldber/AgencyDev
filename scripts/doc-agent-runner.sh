#!/bin/bash
# Documentation Agent Runner using aider

AGENT_NAME="doc-agent"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_ROOT/.agent-state/state.json"
LOCK_FILE="$REPO_ROOT/.agent-state/locks/${AGENT_NAME}.lock"

# Source shared functions
# Provides: validate_config, get_aider_model, find_worktree, update_state,
#           track_api_cost, check_stale_lock, create_alert, get_changed_files,
#           log_event, log_operation_start, log_operation_end, retry_git_push,
#           sync_dependencies
source "$(dirname "$0")/lib/common.sh"

# Validate configuration
if ! validate_config; then
    echo "Error: Configuration validation failed" >&2
    exit 1
fi

# Get available aider model with fallback
PREFERRED_MODEL=$(jq -r '.aider.model // "gpt-4-turbo-preview"' "$REPO_ROOT/.agent-config.json")
AIDER_MODEL=$(get_aider_model "$PREFERRED_MODEL" "gpt-4")

BRANCH=$(jq -r ".branch" "$STATE_FILE")

# Find worktree directory (may be created by vibe-kanban with dynamic name)
WORKTREE_DIR=$(find_worktree "$AGENT_NAME" "$BRANCH")
if [ $? -ne 0 ] || [ -z "$WORKTREE_DIR" ]; then
    echo "Worktree not found, waiting for vibe-kanban to create it..."
    sleep 5
    exit 0  # Exit gracefully, will retry on next run
fi

# Read last processed commit
LAST_COMMIT=$(jq -r ".agents.${AGENT_NAME}.lastProcessedCommit" "$STATE_FILE")

cd "$WORKTREE_DIR"

# Check for refinement requests (developer feedback)
FEEDBACK_DIR="$REPO_ROOT/.agent-state/feedback"
mkdir -p "$FEEDBACK_DIR"
PENDING_REFINEMENT=$(find "$FEEDBACK_DIR" -name "${AGENT_NAME}-*.json" -type f ! -name "*-refinements.json" | \
    xargs jq -r 'select(.processed == false and .agentName == "'"$AGENT_NAME"'") | .refinementId' 2>/dev/null | head -1)

if [ -n "$PENDING_REFINEMENT" ] && [ "$PENDING_REFINEMENT" != "null" ]; then
    # Load refinement request
    REFINEMENT_FILE="$FEEDBACK_DIR/${PENDING_REFINEMENT}.json"
    if [ -f "$REFINEMENT_FILE" ]; then
        REFINEMENT_FEEDBACK=$(jq -r '.feedback' "$REFINEMENT_FILE")
        REFINEMENT_ITERATION=$(jq -r '.iteration' "$REFINEMENT_FILE")
        REFINEMENT_COMMIT=$(jq -r '.commitHash' "$REFINEMENT_FILE")
        
        # Validate refinement commit exists in git history
        if ! git cat-file -e "$REFINEMENT_COMMIT" 2>/dev/null; then
            echo "Warning: Refinement commit $REFINEMENT_COMMIT not found in git history. Marking refinement as invalid."
            jq '.processed = true | .status = "invalid_commit"' "$REFINEMENT_FILE" > "$REFINEMENT_FILE.tmp"
            mv "$REFINEMENT_FILE.tmp" "$REFINEMENT_FILE"
            REFINEMENT_MODE=false
        else
            # Check iteration limit (prevent infinite loops)
            MAX_ITERATIONS=3
            if [ "$REFINEMENT_ITERATION" -gt "$MAX_ITERATIONS" ]; then
                echo "Refinement iteration limit ($MAX_ITERATIONS) exceeded. Marking as needs manual review."
                jq '.processed = true | .status = "max_iterations_exceeded"' "$REFINEMENT_FILE" > "$REFINEMENT_FILE.tmp"
                mv "$REFINEMENT_FILE.tmp" "$REFINEMENT_FILE"
                exit 0
            fi
            
            # Set LAST_COMMIT to the commit being refined to trigger re-processing
            LAST_COMMIT="$REFINEMENT_COMMIT"
            REFINEMENT_MODE=true
            echo "Refinement mode: Processing feedback for commit $REFINEMENT_COMMIT (iteration $REFINEMENT_ITERATION)"
        fi
    else
        REFINEMENT_MODE=false
    fi
else
    REFINEMENT_MODE=false
fi

# Check for new commits (handle empty LAST_COMMIT or refinement mode)
if [ "$REFINEMENT_MODE" = true ]; then
    # Refinement mode: process the specific commit with feedback
    NEW_COMMITS=1
    LATEST_COMMIT="$REFINEMENT_COMMIT"
elif [ -z "$LAST_COMMIT" ] || [ "$LAST_COMMIT" = "null" ] || [ "$LAST_COMMIT" = "" ]; then
    # First run - compare with main branch
    NEW_COMMITS=$(git log --oneline origin/main..origin/"$BRANCH" 2>/dev/null | wc -l)
else
    NEW_COMMITS=$(git log --oneline "$LAST_COMMIT"..origin/"$BRANCH" 2>/dev/null | wc -l)
fi

if [ "$NEW_COMMITS" -eq 0 ] && [ "$REFINEMENT_MODE" != true ]; then
    echo "No new commits to process"
    exit 0
fi

# Check for stale lock and clean if needed (Issue #8)
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

# API Quota Protection - Circuit Breaker (Issue #15 - Alerting)
if ! "$REPO_ROOT/scripts/check-api-quota.sh"; then
    echo "API quota exceeded, exiting" >&2
    create_alert "CRITICAL" "$AGENT_NAME" "API cost limit exceeded - circuit breaker activated"
    rm "$LOCK_FILE"
    exit 1
fi

# PRE-FLIGHT PULL: Ensure worktree is up-to-date before aider runs
# This prevents stale branch issues when agent is already running
echo "Pre-flight: Syncing worktree with remote..."
git fetch origin "$BRANCH" || {
    rm "$LOCK_FILE"
    exit 1
}

# Handle refinement mode vs normal mode
if [ "$REFINEMENT_MODE" = true ]; then
    # Validate commit exists before checkout
    if ! git cat-file -e "$REFINEMENT_COMMIT" 2>/dev/null; then
        echo "Error: Refinement commit $REFINEMENT_COMMIT does not exist in repository" >&2
        log_event "error" "$AGENT_NAME" "refinement_invalid" "Refinement commit not found: $REFINEMENT_COMMIT" "" 0
        rm "$LOCK_FILE"
        exit 1
    fi
    
    # Refinement mode: Checkout the commit being refined
    echo "Refinement mode: Checking out commit $REFINEMENT_COMMIT"
    git checkout "$REFINEMENT_COMMIT" || {
        echo "Error: Could not checkout refinement commit $REFINEMENT_COMMIT" >&2
        log_event "error" "$AGENT_NAME" "refinement_checkout_failed" "Failed to checkout refinement commit" "$REFINEMENT_COMMIT" 0
        rm "$LOCK_FILE"
        exit 1
    }
    
    # Get files that were changed in this commit
    CHANGED_FILES=$(git diff --name-only "$REFINEMENT_COMMIT^..$REFINEMENT_COMMIT" 2>/dev/null)
    LATEST_COMMIT="$REFINEMENT_COMMIT"
    
    # Create refinement prompt
    AIDER_PROMPT="You are a documentation agent. You previously worked on this code, but the developer has provided feedback requesting changes.

DEVELOPER FEEDBACK:
$REFINEMENT_FEEDBACK

Please redo your documentation work with the following in mind:
- Address the specific feedback provided above
- Add/update docstrings for all functions and classes
- Add inline comments for complex logic
- Update README.md if there are API changes
- Ensure all public APIs are documented
- Follow the project's documentation style and use language-appropriate docstring formats

This is refinement iteration $REFINEMENT_ITERATION. Please ensure your changes address the developer's concerns."
else
    # Normal mode: Reset to latest branch state
    git reset --hard origin/"$BRANCH" || {
        rm "$LOCK_FILE"
        exit 1
    }
    
    # PRE-FLIGHT DEPENDENCY SYNC: Ensure dependencies are up-to-date
    echo "Pre-flight: Checking and syncing dependencies..."
    sync_dependencies "$WORKTREE_DIR" "$AGENT_NAME"
    
    # Get latest commit
    LATEST_COMMIT=$(git rev-parse origin/"$BRANCH")
    
    # Get changed files since last processed commit
    CHANGED_FILES=$(get_changed_files "$LAST_COMMIT" "$BRANCH" "source")
    
    # Create normal prompt
    AIDER_PROMPT="You are a documentation agent. Add or update documentation for recently changed files:
- Add/update docstrings for all functions and classes
- Add inline comments for complex logic
- Update README.md if there are API changes
- Ensure all public APIs are documented
- Follow the project's documentation style and use language-appropriate docstring formats"
fi

# Check if there are files to process
if [ -z "$CHANGED_FILES" ]; then
    echo "No changed files to process"
    if [ "$REFINEMENT_MODE" = true ]; then
        # In refinement mode, this is an error
        echo "Error: No files found in refinement commit $REFINEMENT_COMMIT" >&2
        log_event "error" "$AGENT_NAME" "refinement_no_files" "No files found in refinement commit $REFINEMENT_COMMIT" "$REFINEMENT_COMMIT" 0
        rm "$LOCK_FILE"
        exit 1
    else
        rm "$LOCK_FILE"
        exit 0
    fi
fi

# Store commit hash before aider runs (to detect if aider created a new commit)
COMMIT_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")

# Run aider with explicit file paths:
# --yes-always: Fully autonomous operation
# --commit: Let aider create commit with intelligent message
# --map-tokens: Limit context to most relevant files (saves API costs)
aider --model "$AIDER_MODEL" \
      --yes-always \
      --commit \
      --map-tokens 1024 \
      --message "$AIDER_PROMPT" \
      $CHANGED_FILES

# Note: Aider handles git add and commit automatically with --commit flag
# The commit message will be generated by aider based on the changes made

# Check if aider actually created a commit (important for refinement mode)
COMMIT_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ "$COMMIT_BEFORE" = "$COMMIT_AFTER" ] && [ -n "$COMMIT_BEFORE" ]; then
    echo "Warning: Aider did not create a new commit. This may indicate no changes were needed or aider failed."
    if [ "$REFINEMENT_MODE" = true ]; then
        echo "Refinement may not have been applied. Check aider logs for details."
        # Don't mark refinement as processed if no commit was created
        rm "$LOCK_FILE"
        exit 1
    fi
fi

# Track actual API costs using shared function
track_api_cost "$AIDER_MODEL"

# RETRY-ON-PUSH-FAIL: Handle git race conditions with better error messages
if ! retry_git_push "$BRANCH" 5; then
    echo "Error: Failed to push after multiple attempts. Manual intervention required." >&2
    rm "$LOCK_FILE"
    exit 1
fi

# Get the actual commit hash that was just created (after aider ran and pushed)
# This is important for refinement mode - we need the NEW commit, not the old one
ACTUAL_COMMIT=$(git rev-parse HEAD)

# Update state with the actual commit that was just created (using shared function with locking)
update_state "$AGENT_NAME" "lastProcessedCommit" "$ACTUAL_COMMIT"

# Handle refinement completion
if [ "$REFINEMENT_MODE" = true ]; then
    # Mark refinement as processed
    jq ".processed = true | .status = \"completed\" | .iteration = $((REFINEMENT_ITERATION + 1))" \
       "$REFINEMENT_FILE" > "$REFINEMENT_FILE.tmp"
    mv "$REFINEMENT_FILE.tmp" "$REFINEMENT_FILE"
    
    # Move task back to "In Progress" or "Done" in vibe-kanban
    # Use the actual new commit hash, not the old refinement commit
    "$REPO_ROOT/scripts/vibe-kanban-sync.sh" "$AGENT_NAME" "in_progress" "$ACTUAL_COMMIT"
    echo "Refinement completed: processed commit $REFINEMENT_COMMIT, created new commit $ACTUAL_COMMIT"
else
    # Normal completion
    "$REPO_ROOT/scripts/vibe-kanban-sync.sh" "$AGENT_NAME" "done" "$ACTUAL_COMMIT"
fi

# Release lock and log operation completion
log_operation_end "$AGENT_NAME" "agent_run" "success" "Agent run completed successfully" "$ACTUAL_COMMIT"
rm "$LOCK_FILE"
