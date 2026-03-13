#!/bin/bash
#
# Quick setup: prepares your project for wai-loop
#
# Usage: Run this in your project directory
#   curl -fsSL https://raw.githubusercontent.com/mikwiseman/wai-loop/main/setup.sh | bash

set -euo pipefail

echo "Setting up wai-loop..."

# Create memory directory
mkdir -p memory

# Create failed-experiments.md if it doesn't exist
if [ ! -f memory/failed-experiments.md ]; then
  cat > memory/failed-experiments.md << 'EOF'
# Failed Experiments

Record approaches that didn't work so the agent doesn't repeat them.

## Format

```
## [YYYY-MM-DD] What was attempted
Result: what happened
Conclusion: why it didn't work. Do not try again without a new argument.
```
EOF
  echo "Created memory/failed-experiments.md"
fi

# Create successful-fixes.md if it doesn't exist
if [ ! -f memory/successful-fixes.md ]; then
  cat > memory/successful-fixes.md << 'EOF'
# Successful Fixes

Record approaches that worked so patterns can be reused.

## Format

```
## [YYYY-MM-DD] What was fixed
Approach: what worked
Why: why this approach was effective
```
EOF
  echo "Created memory/successful-fixes.md"
fi

# Add memory instruction to CLAUDE.md if it exists
if [ -f CLAUDE.md ]; then
  if ! grep -q "failed-experiments" CLAUDE.md; then
    echo "" >> CLAUDE.md
    echo "## Memory" >> CLAUDE.md
    echo "Before starting work, read memory/failed-experiments.md — do not repeat approaches that already failed." >> CLAUDE.md
    echo "After a failed approach, write to memory/failed-experiments.md with the date and reason." >> CLAUDE.md
    echo "All command output goes to files (> file.log 2>&1). Read only grep results." >> CLAUDE.md
    echo "Added memory instructions to CLAUDE.md"
  else
    echo "CLAUDE.md already has memory instructions"
  fi
else
  echo "No CLAUDE.md found. Run 'claude' then '/init' to create one, then run this script again."
fi

# Add *.log to .gitignore
if [ -f .gitignore ]; then
  if ! grep -q '\.log' .gitignore; then
    echo '*.log' >> .gitignore
    echo "Added *.log to .gitignore"
  fi
else
  echo '*.log' > .gitignore
  echo "Created .gitignore with *.log"
fi

# Download run.sh
curl -fsSL https://raw.githubusercontent.com/mikwiseman/wai-loop/main/run.sh -o run.sh
chmod +x run.sh
echo "Downloaded run.sh"

# Download default prompt
if [ ! -f PROMPT.md ]; then
  curl -fsSL https://raw.githubusercontent.com/mikwiseman/wai-loop/main/PROMPT.md -o PROMPT.md
  echo "Downloaded PROMPT.md (edit this for your project)"
fi

echo ""
echo "Done! Next steps:"
echo "  1. Edit PROMPT.md for your project (test command, grep pattern, etc.)"
echo "  2. Review CLAUDE.md — make sure memory instructions are there"
echo "  3. Run: tmux new -s loop && ./run.sh"
echo "  4. Detach: Ctrl+B, D. Check progress: git log --oneline"
