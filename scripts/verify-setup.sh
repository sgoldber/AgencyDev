#!/bin/bash
# Verify all components are properly configured

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Verifying Multi-Agent Development Environment Setup ==="
echo ""

# Check aider
echo -n "Checking aider... "
if command -v aider &> /dev/null; then
    echo "✓ Installed ($(aider --version 2>/dev/null || echo 'version unknown'))"
else
    echo "✗ NOT INSTALLED"
    echo "  Install with: pip install aider-chat"
fi

# Check Node.js
echo -n "Checking Node.js... "
if command -v node &> /dev/null; then
    echo "✓ Installed ($(node --version))"
else
    echo "✗ NOT INSTALLED"
    echo "  Install with: brew install node (macOS) or apt-get install nodejs (Linux)"
fi

# Check OpenAI API Key
echo -n "Checking OpenAI API Key... "
if [ -n "$OPENAI_API_KEY" ]; then
    echo "✓ Set (${OPENAI_API_KEY:0:10}...)"
else
    echo "✗ NOT SET"
    echo "  Set with: export OPENAI_API_KEY='your-key'"
fi

# Check Git
echo -n "Checking Git... "
if command -v git &> /dev/null; then
    echo "✓ Installed ($(git --version))"
else
    echo "✗ NOT INSTALLED"
fi

# Check repository structure
echo -n "Checking repository structure... "
if [ -d "$REPO_ROOT/staging" ] && [ -d "$REPO_ROOT/scripts" ] && [ -d "$REPO_ROOT/.agent-state" ]; then
    echo "✓ Directories exist"
else
    echo "✗ MISSING DIRECTORIES"
    echo "  Run: mkdir -p staging scripts .agent-state/{locks,logs,events,messages,audit,metrics}"
fi

# Check configuration file
echo -n "Checking .agent-config.json... "
if [ -f "$REPO_ROOT/.agent-config.json" ]; then
    echo "✓ Exists"
else
    echo "✗ MISSING"
    echo "  Create .agent-config.json in repository root"
fi

# Check scripts
echo -n "Checking agent scripts... "
SCRIPT_COUNT=$(ls "$REPO_ROOT/scripts"/*.sh 2>/dev/null | wc -l)
if [ "$SCRIPT_COUNT" -ge 5 ]; then
    echo "✓ Found $SCRIPT_COUNT scripts"
else
    echo "✗ MISSING SCRIPTS"
    echo "  Expected at least 5 scripts in scripts/ directory"
fi

# Check vibe-kanban
echo -n "Checking vibe-kanban... "
if command -v npx &> /dev/null; then
    echo "✓ npx available (vibe-kanban will be installed on first use)"
else
    echo "✗ npx NOT AVAILABLE"
    echo "  Install Node.js to get npx"
fi

echo ""
echo "=== Setup Verification Complete ==="
