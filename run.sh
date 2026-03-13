#!/bin/bash
#
# wai-loop: Universal agent loop with memory
# Inspired by Karpathy's autoresearch, adapted for any project.
#
# Usage:
#   ./run.sh                    # defaults: PROMPT.md, max 3 failures
#   ./run.sh my-prompt.md       # custom prompt file
#   ./run.sh PROMPT.md 5        # custom max failures
#
# Run inside tmux so it survives terminal disconnect:
#   tmux new -s loop
#   ./run.sh
#   # Detach: Ctrl+B, then D
#   # Reattach: tmux attach -t loop

set -euo pipefail

PROMPT_FILE="${1:-PROMPT.md}"
MAX_FAILURES="${2:-3}"
FAILURES=0
ITERATION=0

if [ ! -f "$PROMPT_FILE" ]; then
  echo "Error: $PROMPT_FILE not found."
  echo "Copy one of the examples: cp examples/fix-tests.md PROMPT.md"
  exit 1
fi

if [ ! -f ".gitignore" ] || ! grep -q '\.log' .gitignore; then
  echo "Warning: .gitignore missing or doesn't ignore *.log files."
  echo "Agent creates log files — add '*.log' to .gitignore."
fi

echo "=== wai-loop ==="
echo "Prompt:       $PROMPT_FILE"
echo "Max failures: $MAX_FAILURES"
echo "Started:      $(date)"
echo ""

while true; do
  ITERATION=$((ITERATION + 1))
  LAST_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  echo "--- Iteration $ITERATION ($(date +%H:%M)) ---"

  # Agent works until it exits on its own.
  # No timeout — NEVER STOP means work as long as you can.
  claude -p "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions \
    || true  # Don't crash the loop if agent exits with error

  CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  # Check progress: new commits OR uncommitted changes OR new files
  HAS_NEW_COMMITS=false
  HAS_CHANGES=false

  if [ "$LAST_HEAD" != "$CURRENT_HEAD" ]; then
    HAS_NEW_COMMITS=true
  fi

  if ! git diff --quiet 2>/dev/null || \
     ! git diff --cached --quiet 2>/dev/null || \
     [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    HAS_CHANGES=true
  fi

  if $HAS_NEW_COMMITS; then
    COMMITS_MADE=$(git rev-list "$LAST_HEAD".."$CURRENT_HEAD" --count 2>/dev/null || echo "?")
    echo "Agent made $COMMITS_MADE commit(s)."
    FAILURES=0
  elif $HAS_CHANGES; then
    echo "Agent left uncommitted changes. Committing."
    git add -A
    git commit -m "wai-loop: auto-commit iteration $ITERATION ($(date +%Y-%m-%d_%H:%M))"
    FAILURES=0
  else
    FAILURES=$((FAILURES + 1))
    echo "No changes. Failure $FAILURES/$MAX_FAILURES."

    if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
      echo ""
      echo "=== Agent stuck after $ITERATION iterations. Stopping. ==="
      echo "Check memory/failed-experiments.md for what was tried."
      break
    fi
  fi

  echo ""
done

echo ""
echo "=== wai-loop finished ==="
echo "Total iterations: $ITERATION"
echo "Run 'git log --oneline' to see what was done."
