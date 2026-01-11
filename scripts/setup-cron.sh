#!/bin/bash
# Setup cron jobs for agent execution
# This script is called automatically by start_feature.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_LOG_DIR="$REPO_ROOT/.agent-state/logs/cron"

# Create log directory
mkdir -p "$CRON_LOG_DIR"

# Check if REPO_ROOT is valid
if [ ! -d "$REPO_ROOT" ]; then
    echo "Error: Invalid repository root: $REPO_ROOT" >&2
    exit 1
fi

# Check if scripts exist
if [ ! -f "$REPO_ROOT/scripts/doc-agent-runner.sh" ]; then
    echo "Error: Agent scripts not found in $REPO_ROOT/scripts/" >&2
    exit 1
fi

echo "Setting up cron jobs for agent execution..."

# Create temporary crontab with new entries
# Remove existing agent-runner and check-feedback entries first
(crontab -l 2>/dev/null | grep -v "agent-runner.sh" | grep -v "check-feedback.sh"; cat <<EOF
# Multi-Agent Development Environment - Agent Runners
# Run every minute with staggered start times to avoid conflicts
* * * * * $REPO_ROOT/scripts/doc-agent-runner.sh >> $CRON_LOG_DIR/doc-agent.log 2>&1
* * * * * sleep 10; $REPO_ROOT/scripts/test-agent-runner.sh >> $CRON_LOG_DIR/test-agent.log 2>&1
* * * * * sleep 20; $REPO_ROOT/scripts/code-review-agent-runner.sh >> $CRON_LOG_DIR/code-review-agent.log 2>&1
* * * * * sleep 30; $REPO_ROOT/scripts/cleanup-agent-runner.sh >> $CRON_LOG_DIR/cleanup-agent.log 2>&1

# Multi-Agent Development Environment - Feedback Detection
# Run every minute with staggered start times
* * * * * $REPO_ROOT/scripts/check-feedback.sh doc-agent >> $CRON_LOG_DIR/feedback.log 2>&1
* * * * * sleep 15; $REPO_ROOT/scripts/check-feedback.sh test-agent >> $CRON_LOG_DIR/feedback.log 2>&1
* * * * * sleep 30; $REPO_ROOT/scripts/check-feedback.sh code-review-agent >> $CRON_LOG_DIR/feedback.log 2>&1
EOF
) | crontab -

if [ $? -eq 0 ]; then
    echo "Cron jobs installed successfully."
    echo "Use 'crontab -l' to view installed jobs"
    echo "Use 'crontab -r' to remove all cron jobs (use with caution)"
    echo "Logs will be written to: $CRON_LOG_DIR"
else
    echo "Error: Failed to install cron jobs" >&2
    exit 1
fi
