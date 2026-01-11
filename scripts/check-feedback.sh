#!/bin/bash
# Check for developer feedback in vibe-kanban and create refinement requests

AGENT_NAME=$1
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEEDBACK_FILE="$REPO_ROOT/.agent-state/feedback/${AGENT_NAME}-refinements.json"
VIBE_KANBAN_TASKS="$REPO_ROOT/.vibe-kanban/tasks/${AGENT_NAME}.json"

# Initialize feedback file if it doesn't exist
if [ ! -f "$FEEDBACK_FILE" ]; then
    cat > "$FEEDBACK_FILE" <<EOF
{
  "refinements": [],
  "lastChecked": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
fi

# Source shared functions for alerting
source "$(dirname "$0")/lib/common.sh"

# Check vibe-kanban for tasks in "Issues Found" column with comments
if [ -f "$VIBE_KANBAN_TASKS" ]; then
    # Check for tasks in "Issues Found" column
    ISSUES_FOUND=$(jq -r '.tasks[] | select(.status == "Issues Found" or .column == "Issues Found")' "$VIBE_KANBAN_TASKS" 2>/dev/null)
    
    if [ -n "$ISSUES_FOUND" ]; then
        # Extract comments/feedback from task
        TASK_ID=$(echo "$ISSUES_FOUND" | jq -r '.id' | head -1)
        COMMENTS=$(echo "$ISSUES_FOUND" | jq -r '.comments[]?.text' 2>/dev/null | head -5)
        COMMIT_HASH=$(echo "$ISSUES_FOUND" | jq -r '.commitHash' | head -1)
        
        if [ -n "$COMMENTS" ] && [ "$COMMENTS" != "null" ]; then
            # Check if this refinement already exists
            EXISTING=$(jq -r ".refinements[] | select(.taskId == \"$TASK_ID\" and .processed == false)" "$FEEDBACK_FILE")
            
            if [ -z "$EXISTING" ]; then
                # Create new refinement request
                REFINEMENT_ID="refinement-$(date +%s)"
                cat > "$REPO_ROOT/.agent-state/feedback/${REFINEMENT_ID}.json" <<EOF
{
  "refinementId": "$REFINEMENT_ID",
  "agentName": "$AGENT_NAME",
  "taskId": "$TASK_ID",
  "commitHash": "$COMMIT_HASH",
  "feedback": "$COMMENTS",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "processed": false,
  "iteration": 1
}
EOF
                
                # Add to refinements list
                jq ".refinements += [{\"refinementId\": \"$REFINEMENT_ID\", \"taskId\": \"$TASK_ID\", \"created\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"processed\": false}]" \
                   "$FEEDBACK_FILE" > "$FEEDBACK_FILE.tmp"
                mv "$FEEDBACK_FILE.tmp" "$FEEDBACK_FILE"
                
                echo "Created refinement request: $REFINEMENT_ID"
            fi
        fi
    fi
    
    # Check for refinements that exceeded max iterations and move to Critical/Stuck
    MAX_ITERATIONS=3
    STUCK_REFINEMENTS=$(find "$REPO_ROOT/.agent-state/feedback" -name "${AGENT_NAME}-*.json" -type f ! -name "*-refinements.json" 2>/dev/null | \
        xargs jq -r 'select(.processed == true and .status == "max_iterations_exceeded" and .agentName == "'"$AGENT_NAME"'") | .refinementId' 2>/dev/null)
    
    if [ -n "$STUCK_REFINEMENTS" ]; then
        for REFINEMENT_ID in $STUCK_REFINEMENTS; do
            REFINEMENT_FILE="$REPO_ROOT/.agent-state/feedback/${REFINEMENT_ID}.json"
            if [ -f "$REFINEMENT_FILE" ]; then
                TASK_ID=$(jq -r '.taskId' "$REFINEMENT_FILE")
                STATUS=$(jq -r '.status' "$REFINEMENT_FILE")
                
                if [ "$STATUS" = "max_iterations_exceeded" ]; then
                    # Move task to Critical/Stuck column in vibe-kanban
                    if command -v vibe-kanban-mcp &> /dev/null; then
                        vibe-kanban-mcp update-task \
                          --board "$AGENT_NAME" \
                          --task-id "$TASK_ID" \
                          --status "Critical/Stuck" \
                          --add-comment "⚠️ Refinement failed after $MAX_ITERATIONS iterations. Manual intervention required."
                    fi
                    
                    # Create critical alert
                    create_alert "CRITICAL" "$AGENT_NAME" "Refinement stuck: Task $TASK_ID exceeded $MAX_ITERATIONS iterations"
                fi
            fi
        done
    fi
fi

# Update last checked timestamp
jq ".lastChecked = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" "$FEEDBACK_FILE" > "$FEEDBACK_FILE.tmp"
mv "$FEEDBACK_FILE.tmp" "$FEEDBACK_FILE"
