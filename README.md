# Multi-Agent Development Environment

An autonomous multi-agent development environment using **aider** (OpenAI-powered AI coding assistant) for agents and **vibe-kanban** for orchestration visualization.

## Overview

This system implements a multi-agent architecture where specialized AI agents work collaboratively on code development tasks:

- **Documentation Agent**: Adds and updates documentation for code changes
- **Test Agent**: Writes comprehensive tests for changed code
- **Code Review Agent**: Performs code reviews and identifies issues
- **Cleanup Agent**: Squashes agent commits into clean, human-readable history

## Features

- ✅ **Worktree Isolation**: Each agent operates in its own git worktree to prevent conflicts
- ✅ **State Tracking**: Agents track processed commits to avoid redundant work
- ✅ **Commit Coordination**: Sequential commit ordering prevents branch conflicts
- ✅ **Autonomous Operation**: Agents monitor, process, and commit independently
- ✅ **Failure Recovery**: Agents can resume from failures and retry operations
- ✅ **Visual Orchestration**: Vibe-kanban provides real-time visualization
- ✅ **Feedback Loop**: Developers can request refinements via vibe-kanban
- ✅ **Cost Tracking**: API cost monitoring with circuit breaker protection

## Prerequisites

1. **aider**: AI coding assistant CLI tool
   ```bash
   pip install aider-chat
   ```

2. **vibe-kanban**: Kanban board for AI agent orchestration
   ```bash
   npx vibe-kanban
   ```

3. **OpenAI API Key**: Configured in your environment
   ```bash
   export OPENAI_API_KEY="your-api-key"
   ```

4. **Git**: For worktree management
5. **Node.js**: For vibe-kanban (if using npx)
6. **jq**: For JSON processing in scripts

## Quick Start

### 1. Install Required Tools

```bash
# Install aider
pip install aider-chat

# Install Node.js (if not already installed)
# macOS:
brew install node
# Linux:
sudo apt-get install nodejs npm

# Install jq (if not already installed)
# macOS:
brew install jq
# Linux:
sudo apt-get install jq
```

### 2. Configure OpenAI API Key

Add to your shell profile (`~/.zshrc`, `~/.bashrc`, or `~/.bash_profile`):

```bash
export OPENAI_API_KEY="sk-your-actual-api-key-here"
source ~/.zshrc  # or source ~/.bashrc
```

### 3. Configure the System

Edit `.agent-config.json` to match your project:

```json
{
  "testCommand": "npm test",
  "linterCommand": "npm run lint",
  "aider": {
    "model": "gpt-4-turbo-preview"
  },
  "costLimits": {
    "dailyLimitUSD": 50.0,
    "alertThresholdUSD": 40.0
  }
}
```

### 4. Verify Setup

```bash
./scripts/verify-setup.sh
```

### 5. Start a Feature Branch

```bash
./scripts/start_feature.sh my-feature-branch
```

This will:
- Create a new feature branch from main
- Initialize agent state
- Set up worktrees (or prepare for vibe-kanban)
- Configure aider in each worktree
- Initialize vibe-kanban boards
- Set up cron jobs for agent execution

### 6. Launch Vibe-Kanban

```bash
npx vibe-kanban
```

### 7. Develop and Monitor

1. Work in the `staging/` directory
2. Commit your code changes
3. Watch vibe-kanban to see agents processing commits
4. Review agent-generated code using vibe-kanban's diff tool
5. Provide feedback if needed (move task to "Issues Found" and add comments)

### 8. Clean Up

When done with the feature:

```bash
./scripts/end_feature.sh my-feature-branch
```

## Directory Structure

```
.
├── staging/              # Developer workspace
├── doc-agent/            # Worktree for documentation agent
├── test-agent/           # Worktree for test agent
├── code-review-agent/    # Worktree for code review agent
├── cleanup-agent/        # Worktree for cleanup agent
├── .agent-state/         # Shared state directory
│   ├── state.json        # Global agent state tracking
│   ├── locks/            # File locks for coordination
│   ├── logs/             # Agent execution logs
│   ├── events/           # Event queue
│   ├── messages/         # Inter-agent communication
│   ├── audit/            # Audit trail logs
│   ├── metrics/          # Performance metrics
│   └── feedback/         # Developer feedback and refinement requests
├── .agent-interfaces/    # Agent interface definitions
├── .vibe-kanban/         # Vibe-kanban configuration
└── scripts/
    ├── start_feature.sh   # Initialize feature branch
    ├── end_feature.sh     # Cleanup worktrees
    ├── setup-cron.sh      # Set up cron jobs
    ├── verify-setup.sh    # Verify installation
    ├── doc-agent-runner.sh
    ├── test-agent-runner.sh
    ├── code-review-agent-runner.sh
    ├── cleanup-agent-runner.sh
    ├── check-feedback.sh
    ├── check-api-quota.sh
    ├── vibe-kanban-sync.sh
    ├── health-check.sh
    ├── rollback_agent_work.sh
    └── lib/
        └── common.sh      # Shared utility functions
```

## Agent Workflow

1. **Developer commits code** in `staging/` directory
2. **Documentation Agent** processes the commit:
   - Adds/updates docstrings
   - Updates README if needed
   - Commits with `docs:` prefix
3. **Test Agent** waits for doc-agent, then:
   - Writes tests for changed code
   - Runs tests and fixes failures
   - Commits with `test:` prefix
4. **Code Review Agent** waits for test-agent, then:
   - Reviews code for issues
   - Generates CODE_REVIEW.md
   - Commits with `review:` prefix
5. **Cleanup Agent** waits for all agents, then:
   - Squashes agent commits
   - Creates clean commit message
   - Pushes final result

## Feedback and Refinement

Developers can request agents to redo their work:

1. Review agent work in vibe-kanban
2. Move task to "Issues Found" column
3. Add a comment with specific feedback
4. The `check-feedback.sh` script detects the comment
5. Agent re-processes with feedback included
6. Maximum 3 refinement iterations per task

## Monitoring

### Health Check

```bash
./scripts/health-check.sh [agent-name]
```

### View Logs

```bash
# Agent logs
tail -f .agent-state/logs/doc-agent-$(date +%Y%m%d).jsonl

# Cron logs
tail -f .agent-state/logs/cron/doc-agent.log

# Alerts
cat .agent-state/alerts/CRITICAL-$(date +%Y%m%d).log
```

### Cost Tracking

Check daily API costs:

```bash
cat .agent-state/metrics/daily_cost.json
```

## Configuration

### `.agent-config.json`

Key configuration options:

- `testCommand`: Command to run tests (e.g., `"npm test"`, `"pytest"`)
- `aider.model`: OpenAI model to use (e.g., `"gpt-4-turbo-preview"`)
- `costLimits.dailyLimitUSD`: Maximum daily API cost
- `costLimits.alertThresholdUSD`: Cost threshold for warnings

## Troubleshooting

### Agents Not Running

1. Check cron jobs: `crontab -l`
2. Check logs: `.agent-state/logs/cron/`
3. Verify setup: `./scripts/verify-setup.sh`
4. Check health: `./scripts/health-check.sh`

### API Quota Exceeded

1. Check cost file: `.agent-state/metrics/daily_cost.json`
2. Increase limit in `.agent-config.json`
3. Or wait for daily reset (midnight)

### Worktree Issues

1. Check if worktrees exist: `git worktree list`
2. Remove stale worktrees: `git worktree remove <name> --force`
3. Re-run `start_feature.sh`

### Lock File Stuck

Locks are automatically cleaned if older than 1 hour. To manually remove:

```bash
rm .agent-state/locks/<agent-name>.lock
```

## Advanced Usage

### Manual Agent Execution

```bash
# Run a specific agent manually
./scripts/doc-agent-runner.sh
./scripts/test-agent-runner.sh
```

### Rollback Agent Work

```bash
./scripts/rollback_agent_work.sh <branch-name> [commit-hash|tag-name]
```

### Disable Cron Jobs

```bash
crontab -l | grep -v "agent-runner.sh" | grep -v "check-feedback.sh" | crontab -
```

## Best Practices

1. **Start Small**: Test with a simple feature branch first
2. **Monitor Costs**: Keep an eye on API usage, especially during initial setup
3. **Review Agent Work**: Always review agent-generated code before merging
4. **Use Feedback Loop**: Provide specific feedback when agents need refinement
5. **Clean Up**: Use `end_feature.sh` to clean up when done

## Contributing

This is a reference implementation. Feel free to:
- Customize agent prompts for your project
- Add new agents for specific tasks
- Modify the workflow to match your needs
- Share improvements and feedback

## License

See the original plan document for details.

## Support

For issues or questions, refer to the comprehensive plan document:
`Multi-Agent Development Environment Plan - Aider & Vibe-Kanban.md`
