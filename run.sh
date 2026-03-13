#!/bin/bash
#
# wai-loop — zero-config AI agent loop with memory.
#
# Describe a goal → the script sets up everything and starts the loop.
#
# Usage:
#   ./run.sh "fix all failing tests"
#   ./run.sh "improve test coverage to 80%"
#   ./run.sh "optimize the slowest API endpoint"
#   ./run.sh custom-prompt.md              # advanced: full prompt file
#   ./run.sh "goal" --max-failures 5       # custom failure limit
#
# Overnight:
#   tmux new -s loop && ./run.sh "fix all failing tests"
#   # Detach: Ctrl+B, D | Reattach: tmux attach -t loop

set -euo pipefail

# ─── Parse arguments ──────────────────────────────────────────────

GOAL=""
PROMPT_FILE=""
MAX_FAILURES=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-failures) MAX_FAILURES="$2"; shift 2 ;;
    -h|--help)
      echo "wai-loop — zero-config AI agent loop with memory."
      echo ""
      echo "Usage:"
      echo "  ./run.sh \"fix all failing tests\""
      echo "  ./run.sh \"improve test coverage to 80%\""
      echo "  ./run.sh \"optimize the slowest API endpoint\""
      echo "  ./run.sh custom-prompt.md"
      echo "  ./run.sh \"goal\" --max-failures 5"
      exit 0
      ;;
    *)
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
  echo "Usage: ./run.sh \"your goal\""
  echo "       ./run.sh --help"
  exit 1
fi

# ─── Check prerequisites ─────────────────────────────────────────

if ! command -v claude &>/dev/null; then
  echo "Claude Code is required."
  echo "Install: curl -fsSL https://claude.ai/install.sh | bash"
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo "Git is required."
  exit 1
fi

# ─── Auto-setup (first run) ──────────────────────────────────────

echo "=== Setup ==="

# Git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Initializing git..."
  git init
  [ -n "$(ls)" ] && git add -A && git commit -m "Initial commit (before wai-loop)"
fi

# CLAUDE.md — project description for the agent
if [ ! -f "CLAUDE.md" ]; then
  echo "Generating CLAUDE.md (project analysis)..."
  claude -p "Analyze this project directory. Create a file called CLAUDE.md with:
- What the project does (1-2 sentences)
- Tech stack
- How to run tests (if applicable)
- Key conventions
Keep it under 30 lines. Write the file directly." \
    --dangerously-skip-permissions 2>/dev/null || true
  if [ ! -f "CLAUDE.md" ]; then
    echo "# Project" > CLAUDE.md
    echo "Could not auto-generate CLAUDE.md. Edit it manually."
  fi
  echo "Created CLAUDE.md"
fi

# Memory instructions in CLAUDE.md
if ! grep -q "failed-experiments" CLAUDE.md 2>/dev/null; then
  cat >> CLAUDE.md << 'MEMRULE'

## Memory
Before starting work, read memory/failed-experiments.md — do not repeat approaches that already failed.
After a failed approach, write to memory/failed-experiments.md with the date and reason.
After a successful fix, write a note to memory/successful-approaches.md with the date.
All command output goes to files (> file.log 2>&1). Read only grep results.
MEMRULE
fi

# Memory files
mkdir -p memory
[ ! -f "memory/failed-experiments.md" ] && echo "# Failed Experiments" > memory/failed-experiments.md
[ ! -f "memory/successful-approaches.md" ] && echo "# Successful Approaches" > memory/successful-approaches.md

# .gitignore
if [ -f ".gitignore" ]; then
  grep -q '\.log' .gitignore 2>/dev/null || echo '*.log' >> .gitignore
else
  echo '*.log' > .gitignore
fi

echo "Setup complete."
echo ""

# ─── Build prompt ─────────────────────────────────────────────────

if [ -n "$PROMPT_FILE" ]; then
  PROMPT="$(cat "$PROMPT_FILE")"
  echo "Prompt: $PROMPT_FILE"
else
  PROMPT="Read memory/failed-experiments.md — these are approaches that already failed. Do not repeat them.

Your goal: $GOAL

Work toward this goal step by step:
1. Figure out what to do next.
2. Run the relevant command. Redirect ALL output to a file: command > result.log 2>&1
3. Read only the key result: grep for the relevant line in result.log
4. If the step worked — git commit with a clear description of what changed.
5. If the step didn't work — write to memory/failed-experiments.md with today's date and why it failed.
6. Move to the next step.

Rules:
- ALL command output goes to files. Read only grep results. Never dump full logs.
- git commit after each successful change.
- Write to memory/failed-experiments.md after each failed attempt.

NEVER STOP. Keep working until the goal is fully achieved."
  echo "Goal: $GOAL"
fi

# ─── Main loop ────────────────────────────────────────────────────

FAILURES=0
ITERATION=0

echo ""
echo "=== wai-loop started ($(date)) ==="
echo ""

while true; do
  ITERATION=$((ITERATION + 1))
  LAST_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  echo "--- Iteration $ITERATION ($(date +%H:%M)) ---"

  # Agent works until it exits. No timeout.
  echo "$PROMPT" | claude -p --dangerously-skip-permissions 2>/dev/null || true

  CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  # Progress check
  if [ "$LAST_HEAD" != "$CURRENT_HEAD" ]; then
    COMMITS=$(git rev-list "$LAST_HEAD".."$CURRENT_HEAD" --count 2>/dev/null || echo "?")
    echo "→ $COMMITS new commit(s)"
    FAILURES=0
  elif ! git diff --quiet 2>/dev/null || \
       ! git diff --cached --quiet 2>/dev/null || \
       [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    echo "→ Uncommitted changes. Auto-committing."
    git add -A
    git commit -m "wai-loop: iteration $ITERATION ($(date +%Y-%m-%d_%H:%M))"
    FAILURES=0
  else
    FAILURES=$((FAILURES + 1))
    echo "→ No changes ($FAILURES/$MAX_FAILURES)"
    if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
      echo ""
      echo "=== Stuck. Stopping after $ITERATION iterations. ==="
      break
    fi
  fi
  echo ""
done

echo ""
echo "=== wai-loop finished ==="
echo "Iterations: $ITERATION | $(date)"
echo "Review: git log --oneline"
