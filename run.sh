#!/bin/bash
#
# wai-loop — zero-config AI agent loop with eval-driven progress.
#
# Describe a goal → the script sets up everything, measures a baseline,
# and loops an AI agent while tracking progress toward the goal.
#
# The key insight: AI proposes changes, deterministic code evaluates them.
# The agent never judges its own work — the eval script does.
#
# Usage:
#   ./run.sh "fix all failing tests"
#   ./run.sh "improve test coverage to 80%"
#   ./run.sh custom-prompt.md
#   ./run.sh "goal" --max-failures 5
#   ./run.sh "goal" --max-iterations 100
#
# Overnight:
#   tmux new -s loop && ./run.sh "fix all failing tests"
#   # Detach: Ctrl+B, D | Reattach: tmux attach -t loop
#   # Stop: Ctrl+C

set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────

cleanup() {
  pkill -P $$ 2>/dev/null || true
  echo ""
  echo "  === Interrupted. Changes are safe in git. ==="
  exit 0
}
trap cleanup INT TERM

log()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  · $*"; }

# Run the eval script, return the metric (single number on last line)
run_eval() {
  if [ -f "memory/eval.sh" ]; then
    local result
    result=$(timeout 120 bash memory/eval.sh 2>/dev/null | tail -1 | tr -dc '0-9.' || echo "")
    echo "${result:-error}"
  else
    echo ""
  fi
}

# Check: current $comparator target
check_goal() {
  local current="$1" comparator="$2" target="$3"
  [[ "$current" =~ ^[0-9]+$ ]] || return 1
  [[ "$target" =~ ^[0-9]+$ ]] || return 1
  case "$comparator" in
    "=="|"=") [ "$current" -eq "$target" ] 2>/dev/null ;;
    "<=")     [ "$current" -le "$target" ] 2>/dev/null ;;
    ">=")     [ "$current" -ge "$target" ] 2>/dev/null ;;
    "<")      [ "$current" -lt "$target" ] 2>/dev/null ;;
    ">")      [ "$current" -gt "$target" ] 2>/dev/null ;;
    *)        return 1 ;;
  esac
}

# ─── Parse arguments ──────────────────────────────────────────────

GOAL=""
PROMPT_FILE=""
MAX_FAILURES=3
MAX_ITERATIONS=50

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-failures)
      if [[ $# -lt 2 ]] || ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-failures requires a number"
        exit 1
      fi
      MAX_FAILURES="$2"
      shift 2
      ;;
    --max-iterations)
      if [[ $# -lt 2 ]] || ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations requires a number"
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    -h|--help)
      echo "wai-loop — zero-config AI agent loop with eval-driven progress."
      echo ""
      echo "Usage:"
      echo "  ./run.sh \"fix all failing tests\""
      echo "  ./run.sh \"improve test coverage to 80%\""
      echo "  ./run.sh custom-prompt.md"
      echo "  ./run.sh \"goal\" --max-failures 5"
      echo "  ./run.sh \"goal\" --max-iterations 100"
      echo ""
      echo "Stop: Ctrl+C (changes are safe in git)"
      exit 0
      ;;
    *)
      if [[ "$1" == *.md ]]; then
        if [ -f "$1" ]; then
          PROMPT_FILE="$1"
        else
          echo "Error: prompt file '$1' not found."
          exit 1
        fi
      elif [ -n "$GOAL" ]; then
        echo "Error: multiple goals provided. Wrap your goal in quotes:"
        echo "  ./run.sh \"fix all failing tests and lint warnings\""
        exit 1
      else
        GOAL="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$GOAL" ] && [ -z "$PROMPT_FILE" ]; then
  echo "Usage: ./run.sh \"your goal\""
  echo "  e.g. ./run.sh \"fix all failing tests\""
  echo "       ./run.sh --help"
  exit 1
fi

# ─── Check prerequisites ─────────────────────────────────────────

if ! command -v claude &>/dev/null; then
  echo "  ✗ Claude Code not found"
  echo "    Install: curl -fsSL https://claude.ai/install.sh | bash"
  exit 1
fi

# Verify Claude is authenticated (catch expired tokens before wasting iterations)
AUTH_CHECK=$(claude -p "Say OK" --max-turns 1 2>&1 || true)
if echo "$AUTH_CHECK" | grep -qi "authentication_error\|OAuth token has expired\|not authenticated\|unauthorized"; then
  echo "  ✗ Claude Code token expired"
  echo "    Run: claude auth login"
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo "  ✗ Git not found"
  exit 1
fi

# ═════════════════════════════════════════════════════════════════
# PHASE 1: Environment (deterministic, no AI)
# ═════════════════════════════════════════════════════════════════

echo ""
echo "  wai-loop"
echo ""
if [ -n "$GOAL" ]; then
  log "Goal  $GOAL"
else
  log "Prompt  $PROMPT_FILE"
fi
echo ""
log "Setting up..."

# Navigate to git root if inside a repo
if git rev-parse --is-inside-work-tree &>/dev/null; then
  cd "$(git rev-parse --show-toplevel)"
fi

# .gitignore FIRST — before any git add
if [ ! -f ".gitignore" ]; then
  cat > .gitignore << 'GITIGNORE_EOF'
*.log
node_modules/
__pycache__/
.venv/
.env
.env.*
*.pem
*.key
.DS_Store
GITIGNORE_EOF
fi
for pattern in '*.log' '.env' '.env.*' '*.pem' '*.key'; do
  grep -qxF "$pattern" .gitignore 2>/dev/null || echo "$pattern" >> .gitignore
done

# Git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  git init -q
  git add -A
  git commit -q -m "Initial commit (before wai-loop)"
fi
ok "Git repo"

# Memory directory
mkdir -p memory
[ ! -f "memory/failed-experiments.md" ] && echo "# Failed Experiments" > memory/failed-experiments.md
[ ! -f "memory/successful-approaches.md" ] && echo "# Successful Approaches" > memory/successful-approaches.md

# ═════════════════════════════════════════════════════════════════
# PHASE 2: Project Setup (AI-powered, goal-aware)
# ═════════════════════════════════════════════════════════════════

# Protected file hashes (set after Phase 2)
PROTECTED_HASH_RUNSH=""
PROTECTED_HASH_EVAL=""

if [ -n "$GOAL" ]; then

  # ── CLAUDE.md ──
  if [ ! -f "CLAUDE.md" ]; then
    claude -p "Analyze this project directory. Use the Write tool to create a file called CLAUDE.md with:
- What the project does (1-2 sentences)
- Tech stack
- How to run tests (if applicable)
- How to build (if applicable)
- Key conventions
Keep it under 30 lines. You MUST use the Write tool to create the file." \
      --dangerously-skip-permissions > /dev/null 2>&1 || true
    if [ ! -f "CLAUDE.md" ]; then
      echo "  ✗ Could not auto-generate CLAUDE.md."
      echo "    Create it manually: describe your project, tech stack, and how to run tests."
      echo "    Then run this script again."
      exit 1
    fi
  fi
  ok "CLAUDE.md"

  # ── Memory instructions ──
  if ! grep -q "failed-experiments" CLAUDE.md 2>/dev/null; then
    cat >> CLAUDE.md << 'MEMRULE'

## Memory
Before starting work, read memory/failed-experiments.md — do not repeat approaches that already failed.
After a failed approach, write to memory/failed-experiments.md with the date and reason.
After a successful fix, write a note to memory/successful-approaches.md with the date.
All command output goes to files (> file.log 2>&1). Read only grep results.
MEMRULE
  fi
  ok "Memory initialized"

  # ── Eval spec (the core of the system) ──
  # Skip if eval already exists for this exact goal
  NEEDS_EVAL=true
  if [ -f "memory/eval.sh" ] && [ -f "memory/eval-target.txt" ]; then
    if [ -f "memory/eval-goal.txt" ] && grep -qxF "$GOAL" memory/eval-goal.txt 2>/dev/null; then
      NEEDS_EVAL=false
      ok "Eval spec (cached)"
    else
      # Goal changed — re-create eval
      rm -f memory/eval.sh memory/eval-target.txt memory/eval-comparator.txt memory/eval-baseline.txt memory/eval-goal.txt memory/baseline.md
    fi
  fi

  if [ "$NEEDS_EVAL" = true ]; then
    log "Creating eval..."
    timeout 600 claude -p "You are preparing a project for an autonomous AI agent loop.

The goal: \"$GOAL\"

Read CLAUDE.md first — it contains the tech stack and commands you need.

Do these steps IN ORDER:

1. INSTALL DEPENDENCIES if needed (package.json → npm install, requirements.txt → pip install, etc.).
   Redirect output to setup-deps.log. If nothing to install, skip.

2. CREATE THE EVAL SCRIPT — Use the Write tool to create memory/eval.sh
   This is a bash script that measures progress toward the goal.
   It MUST:
   - Run the measurement command for this goal
   - Extract the key metric as a single number
   - Print ONLY that number on the last line — nothing else
   - Complete in under 120 seconds (use timeout)

   Examples of what eval.sh should look like:

   For 'fix all failing tests':
     #!/bin/bash
     pytest --tb=no -q > /tmp/eval-output.log 2>&1 || true
     grep -oP '\d+ failed' /tmp/eval-output.log | grep -oP '\d+' || echo '0'

   For 'improve test coverage to 80%':
     #!/bin/bash
     pytest --cov --cov-report=term > /tmp/eval-output.log 2>&1 || true
     grep 'TOTAL' /tmp/eval-output.log | grep -oP '\d+%' | grep -oP '\d+' || echo '0'

   For 'fix ESLint warnings':
     #!/bin/bash
     npx eslint . --format compact > /tmp/eval-output.log 2>&1 || true
     grep -c 'Warning\|Error' /tmp/eval-output.log || echo '0'

   For qualitative goals (refactor, migrate):
     #!/bin/bash
     # Count remaining items to migrate
     grep -rc 'require(' src/ 2>/dev/null || echo '0'

3. CREATE EVAL CONFIG — Use the Write tool to create these files:
   - memory/eval-target.txt — just the target number (e.g., '0' for zero failures)
   - memory/eval-comparator.txt — just the operator: == or <= or >=
   - memory/eval-goal.txt — write exactly: $GOAL

4. TEST IT — Run: bash memory/eval.sh
   Verify it outputs a single number. If not, fix eval.sh.

5. SAVE BASELINE — Use the Write tool to create memory/baseline.md with:
   - The goal
   - Current state in plain English (e.g., '47 tests passing, 12 failing')
   - The eval command being used

Do NOT start fixing anything. Only prepare and measure.
Every command must use timeout. Do NOT start servers or long-running processes." \
      --dangerously-skip-permissions > /dev/null 2>&1 || true

    # Verify eval works by running it
    if [ -f "memory/eval.sh" ]; then
      EVAL_RESULT=$(run_eval)
      if [[ "$EVAL_RESULT" =~ ^[0-9.]+$ ]]; then
        echo "$EVAL_RESULT" > memory/eval-baseline.txt
        ok "Eval verified (baseline: $EVAL_RESULT)"
      else
        warn "Eval returned '$EVAL_RESULT' — falling back to commit-based tracking"
        rm -f memory/eval.sh
      fi
    else
      warn "No eval created — using commit-based tracking"
    fi
  fi

  # Record checksums for protected files
  PROTECTED_HASH_RUNSH=$(shasum run.sh 2>/dev/null | cut -d' ' -f1 || echo "")
  if [ -f "memory/eval.sh" ]; then
    PROTECTED_HASH_EVAL=$(shasum memory/eval.sh 2>/dev/null | cut -d' ' -f1 || echo "")
  fi

  # Commit setup artifacts
  if ! git diff --quiet 2>/dev/null || \
     ! git diff --cached --quiet 2>/dev/null || \
     [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    git add -A
    git commit -q -m "wai-loop: setup for goal" -m "$GOAL"
  fi

  # Display baseline
  if [ -f "memory/eval-baseline.txt" ] && [ -f "memory/eval-target.txt" ]; then
    BASELINE_VAL=$(cat memory/eval-baseline.txt)
    TARGET_VAL=$(cat memory/eval-target.txt)
    echo ""
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │                                         │"
    printf "  │   Baseline: %-10s Target: %-9s│\n" "$BASELINE_VAL" "$TARGET_VAL"
    echo "  │                                         │"
    echo "  └─────────────────────────────────────────┘"
  fi

  echo ""
fi

# ═════════════════════════════════════════════════════════════════
# PHASE 3: Loop (agent works, shell evaluates)
# ═════════════════════════════════════════════════════════════════

# Build prompt
if [ -n "$PROMPT_FILE" ]; then
  PROMPT="$(cat "$PROMPT_FILE")"
else
  BASELINE_CONTEXT=""
  if [ -f "memory/baseline.md" ]; then
    BASELINE_CONTEXT="
Read memory/baseline.md — this is where you started."
  fi

  PROMPT="Read memory/failed-experiments.md — do not repeat approaches that already failed.
${BASELINE_CONTEXT}

Your goal: $GOAL

Work toward this goal step by step:
1. Figure out what to do next.
2. Run the relevant command. Redirect ALL output to a descriptive log file:
   e.g., pytest-run.log, build-output.log, lint-results.log
   Command: your-command > descriptive-name.log 2>&1
3. Read only the key result (e.g., grep 'FAILED\|PASSED\|Error' test-results.log).
   Never dump full logs into context.
4. If the step worked — git commit with a clear description of what changed.
5. If the step didn't work — write to memory/failed-experiments.md with today's date and why.
6. After a successful fix, write a note to memory/successful-approaches.md.
7. Move to the next step.

Rules:
- ALL command output goes to log files. Never dump full logs into context.
- git commit after each successful change.
- Do NOT modify run.sh, memory/eval.sh, or memory/eval-*.txt files.
- Do NOT start background servers or long-running processes.

NEVER STOP. Keep working until the goal is fully achieved."
fi

# Load eval config
HAS_EVAL=false
EVAL_TARGET=""
EVAL_COMPARATOR=""
EVAL_BASELINE=""
if [ -f "memory/eval.sh" ] && [ -f "memory/eval-target.txt" ] && [ -f "memory/eval-comparator.txt" ]; then
  EVAL_TARGET=$(cat memory/eval-target.txt)
  EVAL_COMPARATOR=$(cat memory/eval-comparator.txt)
  EVAL_BASELINE=$(cat memory/eval-baseline.txt 2>/dev/null || echo "?")
  HAS_EVAL=true
fi

FAILURES=0
ITERATION=0
START_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")
START_TIME=$(date +%s)
PREV_METRIC="${EVAL_BASELINE}"
TRAJECTORY="${EVAL_BASELINE}"

log "Loop started ($(date +%H:%M))"
log "Max: $MAX_ITERATIONS iterations, $MAX_FAILURES stalls"
if [ "$HAS_EVAL" = true ]; then
  log "Eval: baseline=$EVAL_BASELINE target=$EVAL_TARGET"
fi
echo ""

while true; do
  ITERATION=$((ITERATION + 1))
  ITER_START=$(date +%s)
  LAST_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  # Safety: max iterations
  if [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
    echo ""
    log "=== Max iterations ($MAX_ITERATIONS) reached. ==="
    break
  fi

  echo "  ── Iteration $ITERATION · $(date +%H:%M) ──────────────────────────────"
  echo ""

  # Agent works until it exits
  # || true: claude exits non-zero on context overflow or interruption — expected.
  claude -p "$PROMPT" --dangerously-skip-permissions || true

  CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")
  ITER_ELAPSED=$(( $(date +%s) - ITER_START ))
  ITER_TIME="$(( ITER_ELAPSED / 60 ))m $(( ITER_ELAPSED % 60 ))s"

  # Auto-commit uncommitted changes (exclude log files)
  if [ "$LAST_HEAD" = "$CURRENT_HEAD" ]; then
    if ! git diff --quiet 2>/dev/null || \
       ! git diff --cached --quiet 2>/dev/null || \
       [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
      git add -A
      git reset -- '*.log' 2>/dev/null || true
      git commit -q -m "wai-loop: auto-save iteration $ITERATION" 2>/dev/null || true
      CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")
    fi
  fi

  # Protect critical files from agent modification
  if [ -n "$PROTECTED_HASH_RUNSH" ]; then
    CURRENT_HASH=$(shasum run.sh 2>/dev/null | cut -d' ' -f1 || echo "")
    if [ "$CURRENT_HASH" != "$PROTECTED_HASH_RUNSH" ]; then
      warn "run.sh was modified by agent — restoring"
      git checkout -- run.sh 2>/dev/null || true
    fi
  fi
  if [ -n "$PROTECTED_HASH_EVAL" ] && [ -f "memory/eval.sh" ]; then
    CURRENT_HASH=$(shasum memory/eval.sh 2>/dev/null | cut -d' ' -f1 || echo "")
    if [ "$CURRENT_HASH" != "$PROTECTED_HASH_EVAL" ]; then
      warn "eval.sh was modified by agent — restoring"
      git checkout -- memory/eval.sh 2>/dev/null || true
    fi
  fi

  # Count new commits this iteration
  COMMIT_COUNT=0
  if [ "$LAST_HEAD" != "none" ] && [ "$CURRENT_HEAD" != "none" ] && [ "$LAST_HEAD" != "$CURRENT_HEAD" ]; then
    COMMIT_COUNT=$(git rev-list "$LAST_HEAD".."$CURRENT_HEAD" --count 2>/dev/null || echo "0")
  fi

  # ── Evaluate progress ──
  if [ "$HAS_EVAL" = true ]; then
    CURRENT_METRIC=$(run_eval)

    if [[ "$CURRENT_METRIC" =~ ^[0-9.]+$ ]]; then
      # Update trajectory (only if metric changed)
      LAST_IN_TRAJECTORY=$(echo "$TRAJECTORY" | sed 's/.* → //')
      if [ "$CURRENT_METRIC" != "$LAST_IN_TRAJECTORY" ]; then
        TRAJECTORY="${TRAJECTORY} → ${CURRENT_METRIC}"
      fi

      # Log to progress file
      echo "$(date +%H:%M) iteration=$ITERATION metric=$CURRENT_METRIC commits=$COMMIT_COUNT" >> memory/progress.log

      # Display
      if [ "$COMMIT_COUNT" -gt 0 ]; then
        ok "$COMMIT_COUNT commit(s) · metric: $CURRENT_METRIC (target: $EVAL_TARGET)    ${ITER_TIME}"
      else
        warn "no commits · metric: $CURRENT_METRIC (target: $EVAL_TARGET)    ${ITER_TIME}"
      fi

      # Goal achieved?
      if check_goal "$CURRENT_METRIC" "$EVAL_COMPARATOR" "$EVAL_TARGET"; then
        echo ""
        log "=== Goal achieved! ($TRAJECTORY) ==="
        break
      fi

      # Stall detection (metric unchanged = stall)
      if [ "$CURRENT_METRIC" = "$PREV_METRIC" ]; then
        FAILURES=$((FAILURES + 1))
        if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
          echo ""
          log "=== Stalled at $CURRENT_METRIC (target: $EVAL_TARGET). ==="
          break
        fi
      else
        FAILURES=0
      fi
      PREV_METRIC="$CURRENT_METRIC"

    else
      # Eval failed this iteration — fall back to commit-based
      if [ "$COMMIT_COUNT" -gt 0 ]; then
        ok "$COMMIT_COUNT commit(s) (eval unavailable)    ${ITER_TIME}"
        FAILURES=0
      else
        FAILURES=$((FAILURES + 1))
        warn "no changes ($FAILURES/$MAX_FAILURES)    ${ITER_TIME}"
        if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
          echo ""
          log "=== Stuck. No progress in $MAX_FAILURES iterations. ==="
          break
        fi
      fi
    fi

  else
    # No eval — commit-based progress detection
    if [ "$COMMIT_COUNT" -gt 0 ]; then
      ok "$COMMIT_COUNT commit(s)    ${ITER_TIME}"
      FAILURES=0
    else
      FAILURES=$((FAILURES + 1))
      warn "no changes ($FAILURES/$MAX_FAILURES)    ${ITER_TIME}"
      if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
        echo ""
        log "=== Stuck. No progress in $MAX_FAILURES iterations. ==="
        break
      fi
    fi
  fi

  # Clean up old log files to prevent disk fill
  find . -maxdepth 2 -name "*.log" -not -path "./memory/*" -mmin +60 -delete 2>/dev/null || true

  echo ""
done

# Kill orphaned child processes (servers, watchers, etc.)
pkill -P $$ 2>/dev/null || true

# ─── Summary ──────────────────────────────────────────────────────

FINAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")
TOTAL_COMMITS="0"
if [ "$START_HEAD" != "none" ] && [ "$FINAL_HEAD" != "none" ] && [ "$START_HEAD" != "$FINAL_HEAD" ]; then
  TOTAL_COMMITS=$(git rev-list "$START_HEAD".."$FINAL_HEAD" --count 2>/dev/null || echo "0")
fi

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))
TOTAL_MIN=$(( TOTAL_ELAPSED / 60 ))

echo ""

if [ "$HAS_EVAL" = true ]; then
  FINAL_METRIC=$(run_eval)

  echo "  ┌─────────────────────────────────────────┐"
  echo "  │                                         │"
  printf "  │   Before: %-10s After: %-10s │\n" "$EVAL_BASELINE" "${FINAL_METRIC:-?}"
  printf "  │   Target: %-29s│\n" "$EVAL_TARGET"
  echo "  │                                         │"
  echo "  └─────────────────────────────────────────┘"
  echo ""
  if [ -n "$TRAJECTORY" ]; then
    log "Progress  $TRAJECTORY"
  fi
fi

log "Done in $ITERATION iterations · $TOTAL_COMMITS commits · ${TOTAL_MIN}m"
echo ""
log "Review    git log --oneline"
log "Memory    cat memory/failed-experiments.md"
if [ -n "$GOAL" ]; then
  log "Resume    ./run.sh \"$GOAL\""
fi
echo ""
