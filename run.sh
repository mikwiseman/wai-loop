#!/bin/bash
#
# wai-loop — run an AI agent in a loop on your project.
#
# Usage:
#   ./run.sh "fix all failing tests"
#   ./run.sh "improve test coverage to 80%"
#   ./run.sh my-prompt.md              # advanced: custom prompt file
#   ./run.sh "goal" --max-failures 5   # custom failure limit
#
# Run inside tmux so it survives terminal disconnect:
#   tmux new -s loop && ./run.sh "fix all failing tests"

set -euo pipefail

# --- Parse arguments ---

GOAL=""
PROMPT_FILE=""
MAX_FAILURES=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-failures)
      MAX_FAILURES="$2"
      shift 2
      ;;
    *)
      # If it's a .md file that exists, use as prompt file
      if [[ "$1" == *.md ]] && [ -f "$1" ]; then
        PROMPT_FILE="$1"
      else
        GOAL="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$GOAL" ] && [ -z "$PROMPT_FILE" ]; then
  echo "wai-loop — run an AI agent in a loop on your project."
  echo ""
  echo "Usage:"
  echo "  ./run.sh \"fix all failing tests\""
  echo "  ./run.sh \"improve test coverage to 80%\""
  echo "  ./run.sh \"optimize the slowest API endpoint\""
  echo "  ./run.sh \"fix all ESLint warnings\""
  echo "  ./run.sh \"migrate from CommonJS to ES modules\""
  echo ""
  echo "Options:"
  echo "  ./run.sh prompt.md            Use a custom prompt file"
  echo "  ./run.sh \"goal\" --max-failures 5"
  echo ""
  echo "First run sets up memory files automatically."
  exit 1
fi

# --- Auto-setup (first run) ---

if [ ! -d "memory" ]; then
  mkdir -p memory
  echo "Created memory/"
fi

if [ ! -f "memory/failed-experiments.md" ]; then
  cat > memory/failed-experiments.md << 'MEMEOF'
# Failed Experiments

Approaches that didn't work. Agent reads this before each run.

<!-- Format:
## [YYYY-MM-DD] What was attempted
Result: what happened
Conclusion: why it didn't work
-->
MEMEOF
  echo "Created memory/failed-experiments.md"
fi

if [ ! -f "memory/successful-approaches.md" ]; then
  cat > memory/successful-approaches.md << 'MEMEOF'
# Successful Approaches

Approaches that worked. Patterns accumulate here.

<!-- Format:
## [YYYY-MM-DD] What was done
Approach: what worked
Why: why it was effective
-->
MEMEOF
  echo "Created memory/successful-approaches.md"
fi

# Add memory instructions to CLAUDE.md if it exists and doesn't have them
if [ -f "CLAUDE.md" ] && ! grep -q "failed-experiments" CLAUDE.md 2>/dev/null; then
  printf '\n## Memory\nBefore starting work, read memory/failed-experiments.md — do not repeat approaches that already failed.\nAfter a failed approach, write to memory/failed-experiments.md with the date and reason.\nAll command output goes to files (> file.log 2>&1). Read only grep results.\n' >> CLAUDE.md
  echo "Added memory instructions to CLAUDE.md"
fi

# Add *.log to .gitignore
if [ -f ".gitignore" ]; then
  grep -q '\.log' .gitignore 2>/dev/null || echo '*.log' >> .gitignore
else
  echo '*.log' > .gitignore
  echo "Created .gitignore"
fi

# --- Build prompt ---

if [ -n "$PROMPT_FILE" ]; then
  PROMPT="$(cat "$PROMPT_FILE")"
  echo "Using prompt from: $PROMPT_FILE"
else
  PROMPT="Read memory/failed-experiments.md — these are approaches that already failed. Do not repeat them.

Your goal: $GOAL

Work toward this goal. For each step:
1. Figure out what to do next to move toward the goal.
2. Run the relevant command. Redirect ALL output to a file: command > result.log 2>&1
3. Read only the summary line: grep for the relevant result in result.log
4. If the step worked — git commit with a clear description of what you did.
5. If the step didn't work — write what you tried to memory/failed-experiments.md with today's date and why it failed.
6. Move to the next step.

Rules:
- ALL command output goes to files (> file.log 2>&1). Read only grep results. Never dump full logs.
- After each successful change, git commit immediately.
- After each failed attempt, write to memory/failed-experiments.md immediately.

NEVER STOP. Keep working until the goal is fully achieved."
  echo "Goal: $GOAL"
fi

# --- Main loop ---

FAILURES=0
ITERATION=0

echo ""
echo "=== wai-loop ==="
echo "Max failures: $MAX_FAILURES"
echo "Started:      $(date)"
echo ""

while true; do
  ITERATION=$((ITERATION + 1))
  LAST_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  echo "--- Iteration $ITERATION ($(date +%H:%M)) ---"

  # Agent works until it exits on its own. No timeout.
  echo "$PROMPT" | claude -p --dangerously-skip-permissions || true

  CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  # Check progress: new commits, uncommitted changes, or new files
  if [ "$LAST_HEAD" != "$CURRENT_HEAD" ]; then
    COMMITS=$(git rev-list "$LAST_HEAD".."$CURRENT_HEAD" --count 2>/dev/null || echo "?")
    echo "Progress: $COMMITS new commit(s)."
    FAILURES=0
  elif ! git diff --quiet 2>/dev/null || \
       ! git diff --cached --quiet 2>/dev/null || \
       [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    echo "Uncommitted changes found. Committing."
    git add -A
    git commit -m "wai-loop: iteration $ITERATION ($(date +%Y-%m-%d_%H:%M))"
    FAILURES=0
  else
    FAILURES=$((FAILURES + 1))
    echo "No changes. ($FAILURES/$MAX_FAILURES)"
    if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
      echo ""
      echo "=== Stuck after $ITERATION iterations. Stopping. ==="
      break
    fi
  fi
  echo ""
done

echo ""
echo "=== wai-loop finished ==="
echo "Iterations: $ITERATION"
echo "Run 'git log --oneline' to review changes."
