#!/bin/bash
# Usage: ./start_feature.sh <branch-name>

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

BRANCH_NAME=$1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$BRANCH_NAME" ]; then
    echo "Error: Branch name required"
    echo "Usage: ./start_feature.sh <branch-name>"
    exit 1
fi

# Source shared functions for validation
source "$(dirname "$0")/lib/common.sh"

# Step 0: Validate configuration
echo "Validating configuration..."
if ! validate_config; then
    echo "Error: Configuration validation failed. Please fix .agent-config.json" >&2
    exit 1
fi
echo "Configuration validated successfully"

# Step 0.5: Check aider model availability
echo "Checking aider model availability..."
PREFERRED_MODEL=$(jq -r '.aider.model // "gpt-4-turbo-preview"' "$REPO_ROOT/.agent-config.json")
AVAILABLE_MODEL=$(get_aider_model "$PREFERRED_MODEL" "gpt-4")
if [ "$AVAILABLE_MODEL" != "$PREFERRED_MODEL" ]; then
    echo "Warning: Preferred model '$PREFERRED_MODEL' not available, using fallback: '$AVAILABLE_MODEL'" >&2
fi
echo "Using aider model: $AVAILABLE_MODEL"

# Step 1: Create branch from main
cd staging || {
    echo "Error: Failed to change to staging directory" >&2
    exit 1
}

if ! git checkout main; then
    echo "Error: Failed to checkout main branch" >&2
    exit 1
fi

# Only pull/push if remote exists
if git remote get-url origin > /dev/null 2>&1; then
    if ! git pull origin main; then
        echo "Error: Failed to pull from origin/main" >&2
        exit 1
    fi
    if ! git checkout -b "$BRANCH_NAME"; then
        echo "Error: Failed to create branch '$BRANCH_NAME'" >&2
        exit 1
    fi
    if ! git push -u origin "$BRANCH_NAME"; then
        echo "Error: Failed to push branch '$BRANCH_NAME' to origin" >&2
        exit 1
    fi
else
    echo "No remote 'origin' configured, working with local repository only"
    if ! git checkout -b "$BRANCH_NAME"; then
        echo "Error: Failed to create branch '$BRANCH_NAME'" >&2
        exit 1
    fi
fi

# Create agent-specific branches from the feature branch
echo "Creating agent-specific branches..."
AGENT_BRANCHES=("$BRANCH_NAME-doc" "$BRANCH_NAME-test" "$BRANCH_NAME-review" "$BRANCH_NAME-cleanup")
for AGENT_BRANCH in "${AGENT_BRANCHES[@]}"; do
    if ! git branch "$AGENT_BRANCH" "$BRANCH_NAME" 2>/dev/null; then
        # Branch might already exist, that's okay
        echo "  Branch $AGENT_BRANCH already exists or created"
    else
        echo "  ✓ Created branch $AGENT_BRANCH"
    fi
done

# Switch back to main so we can create worktrees for the feature branch
# (Git doesn't allow creating a worktree for a branch that's already checked out)
if ! git checkout main; then
    echo "Error: Failed to checkout main branch after creating feature branch" >&2
    exit 1
fi

# Step 2: Initialize agent state
mkdir -p "$REPO_ROOT/.agent-state/locks" || {
    echo "Error: Failed to create .agent-state/locks directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/logs" || {
    echo "Error: Failed to create .agent-state/logs directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/events" || {
    echo "Error: Failed to create .agent-state/events directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/messages" || {
    echo "Error: Failed to create .agent-state/messages directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/audit" || {
    echo "Error: Failed to create .agent-state/audit directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/metrics" || {
    echo "Error: Failed to create .agent-state/metrics directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/feedback" || {
    echo "Error: Failed to create .agent-state/feedback directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/alerts" || {
    echo "Error: Failed to create .agent-state/alerts directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/.agent-state/dependency-sync" || {
    echo "Error: Failed to create .agent-state/dependency-sync directory" >&2
    exit 1
}
mkdir -p "$REPO_ROOT/scripts/lib" || {
    echo "Error: Failed to create scripts/lib directory" >&2
    exit 1
}

# Initialize state.json
echo "Creating agent state file..."
STATE_FILE="$REPO_ROOT/.agent-state/state.json"
if ! cat > "$STATE_FILE" <<EOF
{
  "branch": "$BRANCH_NAME",
  "lastProcessedCommit": "",
  "metadata": {
    "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "lastUpdated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "version": "1.0"
  },
  "agents": {
    "doc-agent": {
      "lastProcessedCommit": "",
      "status": "idle",
      "lastRun": null,
      "commitQueue": [],
      "metrics": {
        "commitsProcessed": 0,
        "averageProcessingTime": 0,
        "successRate": 1.0,
        "lastError": null
      },
      "handoffRequired": false,
      "humanInterventionNeeded": false
    },
    "test-agent": {
      "lastProcessedCommit": "",
      "status": "idle",
      "lastRun": null,
      "commitQueue": [],
      "metrics": {
        "commitsProcessed": 0,
        "averageProcessingTime": 0,
        "successRate": 1.0,
        "lastError": null
      },
      "handoffRequired": false,
      "humanInterventionNeeded": false
    },
    "code-review-agent": {
      "lastProcessedCommit": "",
      "status": "idle",
      "lastRun": null,
      "commitQueue": [],
      "metrics": {
        "commitsProcessed": 0,
        "averageProcessingTime": 0,
        "successRate": 1.0,
        "lastError": null
      },
      "handoffRequired": false,
      "humanInterventionNeeded": false
    },
    "cleanup-agent": {
      "lastProcessedCommit": "",
      "status": "idle",
      "lastRun": null,
      "commitQueue": [],
      "metrics": {
        "commitsProcessed": 0,
        "averageProcessingTime": 0,
        "successRate": 1.0,
        "lastError": null
      },
      "handoffRequired": false,
      "humanInterventionNeeded": false
    }
  },
  "coordination": {
    "currentSequence": ["doc-agent", "test-agent", "code-review-agent", "cleanup-agent"],
    "activeLocks": [],
    "pendingEvents": []
  }
}
EOF
then
    echo "Error: Failed to create state.json file" >&2
    exit 1
fi

# Verify state.json was created and is valid
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: state.json file was not created" >&2
    exit 1
fi
if ! jq empty "$STATE_FILE" 2>/dev/null; then
    echo "Error: state.json file is not valid JSON" >&2
    exit 1
fi
echo "State file created successfully: $STATE_FILE"

# Step 3: Create worktrees for all agents
# Note: Worktrees must exist for agents to function. Vibe-kanban can create
# additional worktrees for tasks, but we need these base worktrees for the agents.
echo "Creating git worktrees for agents..."

# Find the actual git repository root (works whether staging is a worktree or main repo)
cd "$REPO_ROOT/staging" || {
    echo "Error: Failed to change to staging directory" >&2
    exit 1
}

# Get the git repository root - this works even if staging is a worktree
GIT_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || {
    echo "Error: Failed to determine git repository root" >&2
    exit 1
})

echo "Git repository root: $GIT_REPO_ROOT"

# Change to the git repository root to create worktrees
cd "$GIT_REPO_ROOT" || {
    echo "Error: Failed to change to git repository root: $GIT_REPO_ROOT" >&2
    exit 1
}

# Create worktrees (relative to git repo root, so they'll be siblings of staging)
AGENTS=("doc-agent" "test-agent" "code-review-agent" "cleanup-agent")
# Map agent names to branch suffixes
declare -A AGENT_BRANCH_SUFFIXES
AGENT_BRANCH_SUFFIXES["doc-agent"]="doc"
AGENT_BRANCH_SUFFIXES["test-agent"]="test"
AGENT_BRANCH_SUFFIXES["code-review-agent"]="review"
AGENT_BRANCH_SUFFIXES["cleanup-agent"]="cleanup"

for AGENT in "${AGENTS[@]}"; do
    # Get agent-specific branch name
    AGENT_SUFFIX="${AGENT_BRANCH_SUFFIXES[$AGENT]}"
    AGENT_BRANCH="$BRANCH_NAME-$AGENT_SUFFIX"
    
    # Calculate worktree path relative to REPO_ROOT (not GIT_REPO_ROOT)
    # This ensures worktrees are in the expected location
    WORKTREE_PATH="$REPO_ROOT/$AGENT"
    if [ -d "$WORKTREE_PATH" ]; then
        echo "Checking $AGENT directory..."
        if [ -f "$WORKTREE_PATH/.git" ] || [ -d "$WORKTREE_PATH/.git" ]; then
            # Check if it's already a worktree for this agent branch
            cd "$WORKTREE_PATH"
            CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
            if [ "$CURRENT_BRANCH" = "$AGENT_BRANCH" ]; then
                echo "  ✓ $AGENT worktree already exists on branch $AGENT_BRANCH, skipping"
                cd "$GIT_REPO_ROOT"
                continue
            else
                echo "  Warning: $AGENT worktree exists but on branch '$CURRENT_BRANCH', removing..."
                cd "$GIT_REPO_ROOT"
                git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || rm -rf "$WORKTREE_PATH"
            fi
        else
            echo "  Warning: $AGENT directory exists but is not a worktree, removing..."
            rm -rf "$WORKTREE_PATH"
        fi
    fi
    
    # Create the worktree with agent-specific branch
    echo "  Creating worktree for $AGENT on branch $AGENT_BRANCH..."
    git worktree add "$WORKTREE_PATH" "$AGENT_BRANCH" || {
        echo "Error: Failed to create worktree for $AGENT on branch $AGENT_BRANCH" >&2
        exit 1
    }
    echo "  ✓ Created $AGENT worktree at $WORKTREE_PATH on branch $AGENT_BRANCH"
done

echo "All worktrees created successfully"

# Switch staging back to the feature branch now that worktrees are created
cd "$REPO_ROOT/staging" || {
    echo "Error: Failed to change to staging directory to switch back to feature branch" >&2
    exit 1
}
if ! git checkout "$BRANCH_NAME"; then
    echo "Error: Failed to checkout feature branch '$BRANCH_NAME' in staging" >&2
    exit 1
fi
echo "Switched staging back to branch: $BRANCH_NAME"

# Step 4: Configure aider in each worktree (after worktrees exist)
echo "Configuring aider in worktrees..."
CONFIG_MODEL=$(jq -r '.aider.model // "gpt-4-turbo-preview"' "$REPO_ROOT/.agent-config.json")
for agent in doc-agent test-agent code-review-agent cleanup-agent; do
    WORKTREE_PATH="$REPO_ROOT/$agent"
    if [ -d "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH/.git" ]; then
        if ! cat > "$WORKTREE_PATH/.aider.yml" <<EOF
model: $CONFIG_MODEL
openai-api-key: \${OPENAI_API_KEY}
git: true
EOF
        then
            echo "Error: Failed to create .aider.yml for $agent" >&2
            exit 1
        fi
        echo "  ✓ Configured aider for $agent"
    else
        echo "Error: Worktree $agent does not exist or is not a valid git worktree" >&2
        exit 1
    fi
done

# Step 5: Initialize vibe-kanban (optional - agents work without it)
echo "Initializing vibe-kanban (optional)..."
if ! command -v npx &> /dev/null; then
    echo "Warning: npx not found. Install Node.js to use vibe-kanban."
    echo "  Agents will still work, but you won't have the visual kanban board."
else
    # Try to initialize vibe-kanban project
    if npx vibe-kanban init --project "$BRANCH_NAME-development" 2>&1; then
        echo "  ✓ Vibe-kanban project initialized"
        
        # Create agent boards
        echo "Creating vibe-kanban boards..."
        if npx vibe-kanban create-board --name "doc-agent" \
          --columns "Backlog,In Progress,Review,Done" 2>&1; then
            echo "  ✓ Created doc-agent board"
        else
            echo "  Warning: Failed to create doc-agent board (vibe-kanban may not support this command)"
        fi
        
        if npx vibe-kanban create-board --name "test-agent" \
          --columns "Waiting,Writing Tests,Running Tests,Done" 2>&1; then
            echo "  ✓ Created test-agent board"
        else
            echo "  Warning: Failed to create test-agent board"
        fi
        
        if npx vibe-kanban create-board --name "code-review-agent" \
          --columns "Pending,Reviewing,Issues Found,Approved" 2>&1; then
            echo "  ✓ Created code-review-agent board"
        else
            echo "  Warning: Failed to create code-review-agent board"
        fi
        
        if npx vibe-kanban create-board --name "cleanup-agent" \
          --columns "Waiting,Analyzing,Cleaning,Done" 2>&1; then
            echo "  ✓ Created cleanup-agent board"
        else
            echo "  Warning: Failed to create cleanup-agent board"
        fi
    else
        echo "  Warning: Vibe-kanban initialization failed (this is optional)"
        echo "  Agents will still work without vibe-kanban"
    fi
fi

# Step 6: Set up cron jobs for agent execution
echo "Setting up cron jobs..."
if [ -f "$REPO_ROOT/scripts/setup-cron.sh" ]; then
    "$REPO_ROOT/scripts/setup-cron.sh"
else
    echo "Warning: setup-cron.sh not found. Cron jobs not configured."
    echo "Run scripts/setup-cron.sh manually to set up agent scheduling."
fi

echo ""
echo "========================================"
echo "✅ Feature branch $BRANCH_NAME initialized successfully!"
echo "========================================"
echo ""
echo "Summary:"
echo "  ✓ Branch created: $BRANCH_NAME"
echo "  ✓ Agent state initialized"
echo "  ✓ Worktrees created for all agents"
echo "  ✓ Aider configured in all worktrees"
if command -v npx &> /dev/null; then
    echo "  ✓ Vibe-kanban initialized (if available)"
else
    echo "  ⚠ Vibe-kanban not available (install Node.js to use)"
fi
echo ""
echo "Next steps:"
echo "  1. Start developing in the staging/ directory"
echo "  2. Commit your changes"
echo "  3. Agents will automatically process commits"
if command -v npx &> /dev/null; then
    echo "  4. Launch vibe-kanban: npx vibe-kanban"
fi
echo ""
echo "Verify setup: ./scripts/verify-worktrees.sh $BRANCH_NAME"
echo "========================================"
