#!/bin/bash
# scripts/lib/common.sh - Shared utility functions for agent scripts

# Detect repository root dynamically (recommended approach from plan)
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_FILE="$REPO_ROOT/.agent-state/state.json"
STATE_LOCK="$REPO_ROOT/.agent-state/locks/state.lock"

# Function to update state safely with locking
update_state() {
    local AGENT_NAME=$1
    local FIELD=$2
    local VALUE=$3
    
    # Acquire state lock with timeout
    local TIMEOUT=30
    local ELAPSED=0
    while [ -f "$STATE_LOCK" ] && [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 0.1
        ELAPSED=$((ELAPSED + 1))
    done
    
    if [ -f "$STATE_LOCK" ]; then
        echo "Error: State lock timeout after ${TIMEOUT}s" >&2
        return 1
    fi
    
    touch "$STATE_LOCK"
    
    # Update state atomically
    jq ".agents.${AGENT_NAME}.${FIELD} = \"$VALUE\"" "$STATE_FILE" > "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
    
    # Release lock
    rm "$STATE_LOCK"
    return 0
}

# Function to track actual API costs using OpenAI Usage API
track_api_cost() {
    local MODEL=$1
    local COST_FILE="$REPO_ROOT/.agent-state/metrics/daily_cost.json"
    local COST_LOCK="$REPO_ROOT/.agent-state/locks/cost.lock"
    
    # Initialize cost file if it doesn't exist
    if [ ! -f "$COST_FILE" ]; then
        cat > "$COST_FILE" <<EOF
{
  "date": "$(date +%Y-%m-%d)",
  "totalCostUSD": 0.0,
  "lastReset": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "breakdown": {}
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
  "lastReset": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "breakdown": {}
}
EOF
    fi
    
    # Get usage from OpenAI API for today
    local TODAY=$(date +%Y-%m-%d)
    local USAGE_RESPONSE=$(curl -s "https://api.openai.com/v1/usage?start_date=${TODAY}&end_date=${TODAY}" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" 2>/dev/null)
    
    # Parse cost from response (adjust based on actual API response format)
    # Note: OpenAI Usage API may require different endpoint or authentication
    # This is a placeholder - adjust based on actual API documentation
    local COST=0.0
    if [ -n "$USAGE_RESPONSE" ] && echo "$USAGE_RESPONSE" | jq -e '.data' > /dev/null 2>&1; then
        # Extract cost from API response
        COST=$(echo "$USAGE_RESPONSE" | jq -r '.data[0].cost // 0' 2>/dev/null || echo "0.0")
    else
        # Fallback: Estimate based on model (if API unavailable)
        case "$MODEL" in
            "gpt-4-turbo-preview"|"gpt-4-turbo")
                COST=0.10  # Rough estimate per call
                ;;
            "o3-mini")
                COST=0.05  # Rough estimate per call
                ;;
            *)
                COST=0.10
                ;;
        esac
        echo "Warning: OpenAI Usage API unavailable, using estimate for $MODEL: \$$COST" >&2
    fi
    
    # Acquire cost lock
    local ELAPSED=0
    while [ -f "$COST_LOCK" ] && [ $ELAPSED -lt 30 ]; do
        sleep 0.1
        ELAPSED=$((ELAPSED + 1))
    done
    
    if [ -f "$COST_LOCK" ]; then
        echo "Error: Cost lock timeout" >&2
        return 1
    fi
    
    touch "$COST_LOCK"
    
    # Update cost
    local CURRENT=$(jq -r '.totalCostUSD' "$COST_FILE")
    local NEW_COST=$(echo "$CURRENT + $COST" | bc -l)
    local MODEL_COST=$(jq -r ".breakdown.${MODEL} // 0" "$COST_FILE")
    local NEW_MODEL_COST=$(echo "$MODEL_COST + $COST" | bc -l)
    
    jq ".totalCostUSD = $NEW_COST | .breakdown.${MODEL} = $NEW_MODEL_COST" "$COST_FILE" > "$COST_FILE.tmp"
    mv "$COST_FILE.tmp" "$COST_FILE"
    
    rm "$COST_LOCK"
    return 0
}

# Function to get changed files since last commit
get_changed_files() {
    local LAST_COMMIT=$1
    local BRANCH=$2
    local FILTER=$3  # Optional: "source", "test", "docs", etc.
    
    if [ -z "$LAST_COMMIT" ] || [ "$LAST_COMMIT" = "null" ] || [ "$LAST_COMMIT" = "" ]; then
        # First run - compare with main branch
        CHANGED_FILES=$(git diff --name-only origin/main..HEAD 2>/dev/null)
    else
        CHANGED_FILES=$(git diff --name-only "$LAST_COMMIT"..HEAD 2>/dev/null)
    fi
    
    # Filter files based on type
    if [ -n "$FILTER" ]; then
        case "$FILTER" in
            "source")
                # Exclude test files, docs, etc.
                CHANGED_FILES=$(echo "$CHANGED_FILES" | grep -v -E "(test/|spec/|__tests__|\.test\.|\.spec\.)")
                ;;
            "test")
                # Only test files
                CHANGED_FILES=$(echo "$CHANGED_FILES" | grep -E "(test/|spec/|__tests__|\.test\.|\.spec\.)")
                ;;
            "docs")
                # Documentation files
                CHANGED_FILES=$(echo "$CHANGED_FILES" | grep -E "(\.md$|docs/|README)")
                ;;
        esac
    fi
    
    echo "$CHANGED_FILES"
}

# Function to get agent-specific branch name
get_agent_branch() {
    local BRANCH=$1
    local AGENT=$2
    case "$AGENT" in
        "doc-agent") echo "$BRANCH-doc" ;;
        "test-agent") echo "$BRANCH-test" ;;
        "code-review-agent") echo "$BRANCH-review" ;;
        "cleanup-agent") echo "$BRANCH-cleanup" ;;
        *) echo "$BRANCH" ;;
    esac
}

# Function to validate agent configuration
validate_config() {
    local CONFIG_FILE="$REPO_ROOT/.agent-config.json"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found: $CONFIG_FILE" >&2
        return 1
    fi
    
    # Validate required fields
    if ! jq -e '.testCommand' "$CONFIG_FILE" > /dev/null 2>&1; then
        echo "Error: Missing required field 'testCommand' in $CONFIG_FILE" >&2
        return 1
    fi
    
    if ! jq -e '.aider.model' "$CONFIG_FILE" > /dev/null 2>&1; then
        echo "Error: Missing required field 'aider.model' in $CONFIG_FILE" >&2
        return 1
    fi
    
    # Validate test command exists (if it's a file path)
    local TEST_CMD=$(jq -r '.testCommand' "$CONFIG_FILE")
    if [ -n "$TEST_CMD" ] && [ ! -f "$TEST_CMD" ] && ! command -v "$TEST_CMD" > /dev/null 2>&1; then
        echo "Warning: Test command '$TEST_CMD' may not be available" >&2
    fi
    
    return 0
}

# Function to check and get available aider model with fallback
get_aider_model() {
    local PREFERRED_MODEL=$1
    local FALLBACK_MODEL=${2:-"gpt-4"}
    
    # Model name mapping (for deprecated/preview models)
    case "$PREFERRED_MODEL" in
        "gpt-4-turbo-preview")
            # Check if preview model is available, fallback to gpt-4-turbo or gpt-4
            if aider --model "$PREFERRED_MODEL" --help > /dev/null 2>&1; then
                echo "$PREFERRED_MODEL"
            elif aider --model "gpt-4-turbo" --help > /dev/null 2>&1; then
                echo "gpt-4-turbo"
            else
                echo "$FALLBACK_MODEL"
            fi
            ;;
        "o3-mini")
            # Check if o3-mini is available
            if aider --model "$PREFERRED_MODEL" --help > /dev/null 2>&1; then
                echo "$PREFERRED_MODEL"
            else
                echo "$FALLBACK_MODEL"
            fi
            ;;
        *)
            # For other models, try the preferred first, then fallback
            if aider --model "$PREFERRED_MODEL" --help > /dev/null 2>&1; then
                echo "$PREFERRED_MODEL"
            else
                echo "$FALLBACK_MODEL"
            fi
            ;;
    esac
}

# Function to retry git push with better error messages
retry_git_push() {
    local BRANCH=$1
    local MAX_ATTEMPTS=${2:-5}
    local ATTEMPT=1
    
    while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        # Capture push output for error reporting
        local PUSH_OUTPUT=$(git push origin "$BRANCH" 2>&1)
        local PUSH_EXIT=$?
        
        if [ $PUSH_EXIT -eq 0 ]; then
            return 0
        fi
        
        echo "Push failed (attempt $ATTEMPT/$MAX_ATTEMPTS), rebasing..." >&2
        echo "Error details: $PUSH_OUTPUT" >&2
        
        if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
            echo "Attempting to rebase and retry..." >&2
            if ! git pull --rebase origin "$BRANCH" 2>&1; then
                echo "Error: Rebase failed. Conflict detected, marking for manual resolution" >&2
                echo "Rebase error: $(git pull --rebase origin "$BRANCH" 2>&1)" >&2
                return 1
            fi
        fi
        
        ATTEMPT=$((ATTEMPT + 1))
        sleep 1
    done
    
    echo "Error: Failed to push after $MAX_ATTEMPTS attempts" >&2
    return 1
}

# Function to check and clean stale locks (Issue #8)
check_stale_lock() {
    local LOCK_FILE=$1
    local MAX_AGE=${2:-3600}  # Default: 1 hour in seconds
    
    if [ -f "$LOCK_FILE" ]; then
        # Get lock file modification time (works on both Linux and macOS)
        local LOCK_AGE=0
        if [[ "$OSTYPE" == "darwin"* ]]; then
            LOCK_AGE=$(($(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)))
        else
            LOCK_AGE=$(($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)))
        fi
        
        if [ "$LOCK_AGE" -gt "$MAX_AGE" ]; then
            echo "Warning: Stale lock detected (age: ${LOCK_AGE}s), removing..." >&2
            rm "$LOCK_FILE"
            # Log to audit trail
            mkdir -p "$REPO_ROOT/.agent-state/audit"
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Stale lock removed: $LOCK_FILE (age: ${LOCK_AGE}s)" \
                >> "$REPO_ROOT/.agent-state/audit/stale-locks.log"
            # Create alert for stale lock removal
            create_alert "WARNING" "system" "Stale lock detected and removed: $LOCK_FILE (age: ${LOCK_AGE}s)"
            return 0
        fi
        return 1
    fi
    return 0
}

# Function to find and validate worktree (Issue #10)
find_worktree() {
    local AGENT_NAME=$1
    local BRANCH=$2
    
    # Get agent-specific branch name
    local AGENT_BRANCH=$(get_agent_branch "$BRANCH" "$AGENT_NAME")
    
    # First check state.json for stored path
    local STORED_PATH=$(jq -r ".agents.${AGENT_NAME}.worktreePath // empty" "$STATE_FILE" 2>/dev/null)
    if [ -n "$STORED_PATH" ] && [ "$STORED_PATH" != "null" ] && [ -d "$STORED_PATH/.git" ]; then
        echo "$STORED_PATH"
        return 0
    fi
    
    # Fallback 1: Check standard location
    local WORKTREE_DIR="$REPO_ROOT/$AGENT_NAME"
    if [ -d "$WORKTREE_DIR/.git" ]; then
        # Verify it's on the correct agent branch
        cd "$WORKTREE_DIR"
        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
        if [ "$CURRENT_BRANCH" = "$AGENT_BRANCH" ]; then
            # Store in state for future lookups
            update_state "$AGENT_NAME" "worktreePath" "$WORKTREE_DIR"
            echo "$WORKTREE_DIR"
            return 0
        fi
    fi
    
    # Fallback 2: Look up from vibe-kanban task metadata
    if [ -f "$REPO_ROOT/.vibe-kanban/tasks/${AGENT_NAME}.json" ]; then
        WORKTREE_DIR=$(jq -r ".worktreePath" "$REPO_ROOT/.vibe-kanban/tasks/${AGENT_NAME}.json" 2>/dev/null)
        if [ -n "$WORKTREE_DIR" ] && [ "$WORKTREE_DIR" != "null" ] && [ -d "$WORKTREE_DIR/.git" ]; then
            update_state "$AGENT_NAME" "worktreePath" "$WORKTREE_DIR"
            echo "$WORKTREE_DIR"
            return 0
        fi
    fi
    
    # Fallback 3: Find by agent-specific branch name using git worktree list --porcelain
    WORKTREE_DIR=$(git -C "$REPO_ROOT/staging" worktree list --porcelain 2>/dev/null | \
        awk -v branch="$AGENT_BRANCH" '/^worktree/ {path=$2} /^HEAD/ {if ($2==branch) {print path; exit}; path=""}')
    
    if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR/.git" ]; then
        update_state "$AGENT_NAME" "worktreePath" "$WORKTREE_DIR"
        echo "$WORKTREE_DIR"
        return 0
    fi
    
    return 1
}

# Function to create alerts (Issue #15)
create_alert() {
    local SEVERITY=$1  # CRITICAL, WARNING, INFO
    local AGENT=$2
    local MESSAGE=$3
    local ALERT_DIR="$REPO_ROOT/.agent-state/alerts"
    local ALERT_FILE="$ALERT_DIR/${SEVERITY}-$(date +%Y%m%d).log"
    
    mkdir -p "$ALERT_DIR"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - [$AGENT] $MESSAGE" >> "$ALERT_FILE"
    
    # For critical alerts, also create a flag file for easy monitoring
    if [ "$SEVERITY" = "CRITICAL" ]; then
        touch "$ALERT_DIR/CRITICAL.flag"
    fi
    
    # Also log to structured log
    log_event "alert" "$AGENT" "$SEVERITY" "$MESSAGE"
}

# Function for structured logging (Issue #19)
log_event() {
    local EVENT_TYPE=$1  # alert, operation, error, etc.
    local AGENT=$2
    local CATEGORY=$3
    local MESSAGE=$4
    local COMMIT_HASH=${5:-""}
    local DURATION=${6:-0}
    local LOG_DIR="$REPO_ROOT/.agent-state/logs"
    local LOG_FILE="$LOG_DIR/${AGENT}-$(date +%Y%m%d).jsonl"
    
    mkdir -p "$LOG_DIR"
    
    # Escape message for JSON (simple escaping)
    MESSAGE_ESCAPED=$(echo "$MESSAGE" | sed 's/"/\\"/g')
    
    # Create structured log entry (JSON Lines format)
    cat >> "$LOG_FILE" <<EOF
{"timestamp":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","eventType":"$EVENT_TYPE","agent":"$AGENT","category":"$CATEGORY","message":"$MESSAGE_ESCAPED","commitHash":"$COMMIT_HASH","duration":$DURATION}
EOF
    
    # Also output to stdout for real-time monitoring
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$AGENT] [$CATEGORY] $MESSAGE"
}

# Function to log operation start/end with duration tracking
log_operation_start() {
    local AGENT=$1
    local OPERATION=$2
    local COMMIT_HASH=${3:-""}
    export OPERATION_START_TIME=$(date +%s)
    export CURRENT_OPERATION="$OPERATION"
    export CURRENT_COMMIT_HASH="$COMMIT_HASH"
    log_event "operation_start" "$AGENT" "$OPERATION" "Started" "$COMMIT_HASH" 0
}

log_operation_end() {
    local AGENT=$1
    local OPERATION=$2
    local STATUS=$3  # success, failure, error
    local MESSAGE=${4:-""}
    local DURATION=0
    
    if [ -n "$OPERATION_START_TIME" ]; then
        DURATION=$(($(date +%s) - OPERATION_START_TIME))
    fi
    
    log_event "operation_end" "$AGENT" "$OPERATION" "$STATUS: $MESSAGE" "${CURRENT_COMMIT_HASH:-}" "$DURATION"
    unset OPERATION_START_TIME
    unset CURRENT_OPERATION
    unset CURRENT_COMMIT_HASH
}

# Function to check and sync dependencies
sync_dependencies() {
    local WORKTREE_DIR=$1
    local AGENT_NAME=$2
    
    cd "$WORKTREE_DIR" || return 1
    
    # List of dependency files to check
    local DEPENDENCY_FILES=("package.json" "requirements.txt" "Pipfile" "poetry.lock" "Gemfile" "go.mod" "Cargo.toml" "pom.xml" "build.gradle")
    
    for DEP_FILE in "${DEPENDENCY_FILES[@]}"; do
        if [ -f "$DEP_FILE" ]; then
            # Check if dependency file changed since last sync
            local LAST_SYNC_FILE="$REPO_ROOT/.agent-state/dependency-sync/${DEP_FILE}.hash"
            local CURRENT_HASH=$(git hash-object "$DEP_FILE" 2>/dev/null || echo "")
            
            if [ -z "$CURRENT_HASH" ]; then
                continue  # Skip if we can't get hash
            fi
            
            local NEEDS_SYNC=false
            
            if [ -f "$LAST_SYNC_FILE" ]; then
                local LAST_HASH=$(cat "$LAST_SYNC_FILE")
                if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
                    NEEDS_SYNC=true
                fi
            else
                # First run - always sync
                NEEDS_SYNC=true
            fi
            
            if [ "$NEEDS_SYNC" = true ]; then
                echo "Dependency file $DEP_FILE changed, syncing dependencies..."
                log_event "info" "$AGENT_NAME" "dependency_sync" "Syncing dependencies for $DEP_FILE" "" 0
                
                # Install dependencies based on file type
                local SYNC_SUCCESS=true
                case "$DEP_FILE" in
                    "package.json")
                        if command -v npm &> /dev/null; then
                            npm install || SYNC_SUCCESS=false
                        else
                            echo "Warning: npm not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "requirements.txt")
                        if command -v pip &> /dev/null; then
                            pip install -r requirements.txt || SYNC_SUCCESS=false
                        else
                            echo "Warning: pip not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "Pipfile")
                        if command -v pipenv &> /dev/null; then
                            pipenv install || SYNC_SUCCESS=false
                        else
                            echo "Warning: pipenv not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "poetry.lock")
                        if command -v poetry &> /dev/null; then
                            poetry install || SYNC_SUCCESS=false
                        else
                            echo "Warning: poetry not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "Gemfile")
                        if command -v bundle &> /dev/null; then
                            bundle install || SYNC_SUCCESS=false
                        else
                            echo "Warning: bundle not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "go.mod")
                        if command -v go &> /dev/null; then
                            go mod download && go mod tidy || SYNC_SUCCESS=false
                        else
                            echo "Warning: go not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "Cargo.toml")
                        if command -v cargo &> /dev/null; then
                            cargo fetch || SYNC_SUCCESS=false
                        else
                            echo "Warning: cargo not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "pom.xml")
                        if command -v mvn &> /dev/null; then
                            mvn dependency:resolve || SYNC_SUCCESS=false
                        else
                            echo "Warning: mvn not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                    "build.gradle")
                        if command -v gradle &> /dev/null; then
                            gradle dependencies || SYNC_SUCCESS=false
                        else
                            echo "Warning: gradle not found, skipping dependency sync for $DEP_FILE" >&2
                            SYNC_SUCCESS=false
                        fi
                        ;;
                esac
                
                if [ "$SYNC_SUCCESS" = true ]; then
                    # Update sync hash
                    mkdir -p "$REPO_ROOT/.agent-state/dependency-sync"
                    echo "$CURRENT_HASH" > "$LAST_SYNC_FILE"
                    log_event "success" "$AGENT_NAME" "dependency_sync" "Successfully synced dependencies for $DEP_FILE" "" 0
                else
                    log_event "error" "$AGENT_NAME" "dependency_sync" "Failed to sync dependencies for $DEP_FILE" "" 0
                    create_alert "WARNING" "$AGENT_NAME" "Dependency sync failed for $DEP_FILE - manual intervention may be required"
                fi
            fi
        fi
    done
    
    return 0
}
