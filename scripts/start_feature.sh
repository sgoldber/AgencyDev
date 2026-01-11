#!/bin/bash
# Usage: ./start_feature.sh <branch-name>

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
cd staging
git checkout main
git pull origin main
git checkout -b "$BRANCH_NAME"
git push -u origin "$BRANCH_NAME"

# Step 2: Initialize agent state
mkdir -p "$REPO_ROOT/.agent-state/locks"
mkdir -p "$REPO_ROOT/.agent-state/logs"
mkdir -p "$REPO_ROOT/.agent-state/events"
mkdir -p "$REPO_ROOT/.agent-state/messages"
mkdir -p "$REPO_ROOT/.agent-state/audit"
mkdir -p "$REPO_ROOT/.agent-state/metrics"
mkdir -p "$REPO_ROOT/.agent-state/feedback"
mkdir -p "$REPO_ROOT/.agent-state/alerts"
mkdir -p "$REPO_ROOT/.agent-state/dependency-sync"
mkdir -p "$REPO_ROOT/scripts/lib"

# Initialize state.json
cat > "$REPO_ROOT/.agent-state/state.json" <<EOF
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

# Step 3: Let vibe-kanban create worktrees (if using vibe-kanban)
if command -v npx &> /dev/null; then
    echo "Vibe-kanban will create worktrees when tasks are created"
    echo "Agent scripts will attach to existing worktrees"
else
    # Fallback: Create worktrees manually if vibe-kanban is not available
    cd "$REPO_ROOT"
    git worktree add doc-agent "$BRANCH_NAME" 2>/dev/null || true
    git worktree add test-agent "$BRANCH_NAME" 2>/dev/null || true
    git worktree add code-review-agent "$BRANCH_NAME" 2>/dev/null || true
fi

# Step 4: Configure aider in each worktree (after worktrees exist)
CONFIG_MODEL=$(jq -r '.aider.model // "gpt-4-turbo-preview"' "$REPO_ROOT/.agent-config.json")
for agent in doc-agent test-agent code-review-agent cleanup-agent; do
    if [ -d "$REPO_ROOT/$agent" ]; then
        cat > "$REPO_ROOT/$agent/.aider.yml" <<EOF
model: $CONFIG_MODEL
openai-api-key: \${OPENAI_API_KEY}
git: true
EOF
    else
        echo "Warning: Worktree $agent does not exist yet. Vibe-kanban will create it."
    fi
done

# Step 5: Initialize vibe-kanban
if ! command -v npx &> /dev/null; then
    echo "Warning: npx not found. Install Node.js to use vibe-kanban."
else
    npx vibe-kanban init --project "$BRANCH_NAME-development" || true
    
    # Create agent boards
    npx vibe-kanban create-board --name "doc-agent" \
      --columns "Backlog,In Progress,Review,Done" || true
    npx vibe-kanban create-board --name "test-agent" \
      --columns "Waiting,Writing Tests,Running Tests,Done" || true
    npx vibe-kanban create-board --name "code-review-agent" \
      --columns "Pending,Reviewing,Issues Found,Approved" || true
    npx vibe-kanban create-board --name "cleanup-agent" \
      --columns "Waiting,Analyzing,Cleaning,Done" || true
fi

# Step 6: Set up cron jobs for agent execution
echo "Setting up cron jobs..."
if [ -f "$REPO_ROOT/scripts/setup-cron.sh" ]; then
    "$REPO_ROOT/scripts/setup-cron.sh"
else
    echo "Warning: setup-cron.sh not found. Cron jobs not configured."
    echo "Run scripts/setup-cron.sh manually to set up agent scheduling."
fi

echo "Feature branch $BRANCH_NAME initialized"
echo "Agents configured with aider"
echo "Vibe-kanban boards created"
echo "Cron jobs configured (if setup-cron.sh exists)"
echo "Start vibe-kanban with: npx vibe-kanban"
