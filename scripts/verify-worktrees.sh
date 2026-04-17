#!/bin/bash
# Verify that git worktrees were set up successfully for a feature branch

set -euo pipefail

BRANCH_NAME=${1:-""}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$BRANCH_NAME" ]; then
    echo "Error: Branch name required"
    echo "Usage: ./verify-worktrees.sh <branch-name>"
    echo ""
    echo "Checking for any configured branches..."
    if [ -f "$REPO_ROOT/.agent-state/state.json" ]; then
        BRANCH_NAME=$(jq -r '.branch // empty' "$REPO_ROOT/.agent-state/state.json" 2>/dev/null || echo "")
        if [ -n "$BRANCH_NAME" ] && [ "$BRANCH_NAME" != "null" ]; then
            echo "Found branch in state.json: $BRANCH_NAME"
            echo ""
        else
            echo "No branch found in state.json"
            exit 1
        fi
    else
        echo "No state.json found. Please provide branch name."
        exit 1
    fi
fi

echo "=== Verifying Worktrees for Branch: $BRANCH_NAME ==="
echo ""

# Source shared functions
source "$(dirname "$0")/lib/common.sh"

# Check if staging directory exists and has the branch
echo "1. Checking staging directory..."
if [ -d "$REPO_ROOT/staging" ]; then
    cd "$REPO_ROOT/staging"
    if git rev-parse --verify "$BRANCH_NAME" > /dev/null 2>&1; then
        echo "   ✓ Branch '$BRANCH_NAME' exists in staging"
        CURRENT_BRANCH=$(git branch --show-current)
        echo "   Current branch in staging: $CURRENT_BRANCH"
    else
        echo "   ✗ Branch '$BRANCH_NAME' NOT FOUND in staging"
        echo "   Available branches:"
        git branch -a | sed 's/^/     /'
    fi
else
    echo "   ✗ Staging directory not found at $REPO_ROOT/staging"
fi

echo ""

# Check for worktrees
echo "2. Checking for agent worktrees..."
AGENTS=("doc-agent" "test-agent" "code-review-agent" "cleanup-agent")
WORKTREES_FOUND=0
WORKTREES_MISSING=0

for AGENT in "${AGENTS[@]}"; do
    AGENT_DIR="$REPO_ROOT/$AGENT"
    if [ -d "$AGENT_DIR" ]; then
        if [ -d "$AGENT_DIR/.git" ]; then
            # Check if it's actually a worktree for the correct branch
            cd "$AGENT_DIR"
            WORKTREE_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
            if [ "$WORKTREE_BRANCH" = "$BRANCH_NAME" ]; then
                echo "   ✓ $AGENT: Found at $AGENT_DIR (branch: $WORKTREE_BRANCH)"
                WORKTREES_FOUND=$((WORKTREES_FOUND + 1))
            else
                echo "   ⚠ $AGENT: Found at $AGENT_DIR but on branch '$WORKTREE_BRANCH' (expected: $BRANCH_NAME)"
            fi
        else
            echo "   ✗ $AGENT: Directory exists but is not a git worktree"
        fi
    else
        echo "   ✗ $AGENT: Worktree not found at $AGENT_DIR"
        WORKTREES_MISSING=$((WORKTREES_MISSING + 1))
    fi
done

echo ""

# Check git worktree list
echo "3. Checking git worktree list..."
if [ -d "$REPO_ROOT/staging" ]; then
    cd "$REPO_ROOT/staging"
    echo "   All worktrees:"
    git worktree list 2>/dev/null | sed 's/^/     /' || echo "     (Unable to list worktrees)"
    
    # Check for worktrees on the specific branch
    echo ""
    echo "   Worktrees on branch '$BRANCH_NAME':"
    WORKTREE_COUNT=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "$BRANCH_NAME"; then
            echo "     $line"
            WORKTREE_COUNT=$((WORKTREE_COUNT + 1))
        fi
    done < <(git worktree list --porcelain 2>/dev/null | grep -A 1 "^worktree" | grep -B 1 "$BRANCH_NAME" || true)
    
    if [ $WORKTREE_COUNT -eq 0 ]; then
        echo "     (No worktrees found for branch $BRANCH_NAME)"
    fi
else
    echo "   ✗ Cannot check worktrees - staging directory not found"
fi

echo ""

# Check vibe-kanban configuration
echo "4. Checking vibe-kanban configuration..."
if [ -d "$REPO_ROOT/.vibe-kanban" ]; then
    echo "   ✓ Vibe-kanban directory exists"
    if [ -f "$REPO_ROOT/.vibe-kanban/projects.json" ] || [ -f "$REPO_ROOT/.vibe-kanban/config.json" ]; then
        echo "   ✓ Vibe-kanban configuration files found"
    else
        echo "   ⚠ Vibe-kanban directory exists but no config files found"
    fi
else
    echo "   ✗ Vibe-kanban directory not found"
    echo "   Note: Worktrees are created by vibe-kanban when tasks are created"
fi

echo ""

# Check state.json
echo "5. Checking agent state..."
if [ -f "$REPO_ROOT/.agent-state/state.json" ]; then
    echo "   ✓ State file exists"
    STORED_BRANCH=$(jq -r '.branch // "not set"' "$REPO_ROOT/.agent-state/state.json" 2>/dev/null || echo "error")
    echo "   Branch in state: $STORED_BRANCH"
    
    # Check for stored worktree paths
    for AGENT in "${AGENTS[@]}"; do
        WORKTREE_PATH=$(jq -r ".agents.${AGENT}.worktreePath // \"not set\"" "$REPO_ROOT/.agent-state/state.json" 2>/dev/null || echo "not set")
        if [ "$WORKTREE_PATH" != "not set" ] && [ "$WORKTREE_PATH" != "null" ]; then
            if [ -d "$WORKTREE_PATH" ]; then
                echo "   ✓ $AGENT worktree path stored: $WORKTREE_PATH"
            else
                echo "   ⚠ $AGENT worktree path stored but directory missing: $WORKTREE_PATH"
            fi
        fi
    done
else
    echo "   ✗ State file not found"
fi

echo ""
echo "========================================"
echo "Summary:"
echo "  Worktrees found: $WORKTREES_FOUND / ${#AGENTS[@]}"
echo "  Worktrees missing: $WORKTREES_MISSING / ${#AGENTS[@]}"
echo ""

if [ $WORKTREES_MISSING -gt 0 ]; then
    echo "⚠️  Some worktrees are missing."
    echo ""
    echo "Note: Worktrees are created automatically by vibe-kanban when tasks are created."
    echo "If vibe-kanban is empty, you need to:"
    echo "  1. Create tasks in vibe-kanban (npx vibe-kanban)"
    echo "  2. Or manually create worktrees:"
    echo "     cd $REPO_ROOT/staging"
    echo "     git worktree add ../doc-agent $BRANCH_NAME"
    echo "     git worktree add ../test-agent $BRANCH_NAME"
    echo "     git worktree add ../code-review-agent $BRANCH_NAME"
    echo "     git worktree add ../cleanup-agent $BRANCH_NAME"
else
    echo "✅ All worktrees are set up correctly!"
fi
echo "========================================"
