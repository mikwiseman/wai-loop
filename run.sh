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

# ─── Colors & Symbols ────────────────────────────────────────────

if [ -t 1 ]; then
  RST='\033[0m'
  BOLD='\033[1m'
  DIM='\033[0;90m'
  CYAN='\033[1;36m'
  GREEN='\033[1;32m'
  YELLOW='\033[1;33m'
  RED='\033[1;31m'
  MAG='\033[1;35m'
  WHITE='\033[1;37m'
  BG_GREEN='\033[42;1;37m'
  BG_RED='\033[41;1;37m'
else
  RST='' BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' MAG='' WHITE='' BG_GREEN='' BG_RED=''
fi

# ─── Helpers ──────────────────────────────────────────────────────

cleanup() {
  pkill -P $$ 2>/dev/null || true
  echo ""
  printf "  ${YELLOW}Interrupted.${RST} Changes are safe in git.\n"
  exit 0
}
trap cleanup INT TERM

log()  { printf "  %b\n" "$*"; }
ok()   { printf "  ${GREEN}✓${RST} %b\n" "$*"; }
warn() { printf "  ${YELLOW}·${RST} %b\n" "$*"; }
fail() { printf "  ${RED}✗${RST} %b\n" "$*"; }

# Draw a progress bar: progress_bar <current> <target> <baseline> <comparator>
progress_bar() {
  local current="${1:-0}" target="${2:-0}" baseline="${3:-0}" comparator="${4:->=}"
  local width=30 pct=0

  [[ "$current" =~ ^[0-9]+$ ]] || return
  [[ "$target" =~ ^[0-9]+$ ]] || return
  [[ "$baseline" =~ ^[0-9]+$ ]] || return

  case "$comparator" in
    ">="*|">"*)
      if [ "$target" -gt "$baseline" ] 2>/dev/null; then
        pct=$(( (current - baseline) * 100 / (target - baseline) ))
      elif [ "$target" -eq "$baseline" ] 2>/dev/null; then
        pct=100
      fi
      ;;
    *)
      if [ "$baseline" -gt "$target" ] 2>/dev/null; then
        pct=$(( (baseline - current) * 100 / (baseline - target) ))
      elif [ "$baseline" -eq "$target" ] 2>/dev/null; then
        pct=100
      fi
      ;;
  esac

  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))

  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  local color="$YELLOW"
  [ "$pct" -ge 30 ] && color="$CYAN"
  [ "$pct" -ge 70 ] && color="$GREEN"

  printf "  ${DIM}▐${RST}${color}${bar}${RST}${DIM}▌${RST} ${BOLD}%d%%${RST}" "$pct"
}

# Filter stream-json output to show agent activity with colors
show_agent_progress() {
  local count=0
  while IFS= read -r line; do
    case "$line" in
      *'"type":"tool_use"'*)
        count=$((count + 1))
        local rest="${line#*\"name\":\"}"
        local tool="${rest%%\"*}"
        if [ "$tool" = "Bash" ] && [[ "$line" == *'"description":'* ]]; then
          local d="${line#*\"description\":\"}"
          printf "  ${DIM}│${RST} ${WHITE}%s${RST}\n" "${d%%\"*}"
        elif [[ "$line" == *'"file_path":'* ]]; then
          local fp="${line#*\"file_path\":\"}"
          fp="${fp%%\"*}"
          printf "  ${DIM}│ → %s %s${RST}\n" "$tool" "${fp##*/}"
        else
          printf "  ${DIM}│ → %s${RST}\n" "$tool"
        fi
        ;;
    esac
  done
  if [ "$count" -gt 0 ]; then
    printf "  ${DIM}│ %d actions${RST}\n" "$count"
    printf "  ${DIM}│${RST}\n"
  fi
}

# Run the eval script, return the metric (single number on last line)
run_eval() {
  if [ -f "memory/eval.sh" ]; then
    local result
    result=$(bash memory/eval.sh 2>/dev/null | tail -1 | tr -dc '0-9.' || echo "")
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
  fail "Claude Code not found"
  echo "    Install: curl -fsSL https://claude.ai/install.sh | bash"
  exit 1
fi

# Multi-profile support: if CLAUDE_CONFIG_DIR is not already set,
# read the default profile from ~/.claude-default (matches the zsh wrapper in .zshrc).
# Without this, the bare binary defaults to ~/.claude/ which may have no auth tokens.
if [ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$HOME/.claude-default" ]; then
  PROFILE=$(cat "$HOME/.claude-default")
  if [ -d "$HOME/.claude-$PROFILE" ]; then
    export CLAUDE_CONFIG_DIR="$HOME/.claude-$PROFILE"
  fi
fi

if ! command -v git &>/dev/null; then
  fail "Git not found"
  exit 1
fi

# ═════════════════════════════════════════════════════════════════
# PHASE 1: Environment (deterministic, no AI)
# ═════════════════════════════════════════════════════════════════

echo ""
printf "  ${CYAN}${BOLD}wai-loop${RST}\n"
echo ""
if [ -n "$GOAL" ]; then
  printf "  ${BOLD}Goal${RST}  %s\n" "$GOAL"
else
  printf "  ${BOLD}Prompt${RST}  %s\n" "$PROMPT_FILE"
fi
echo ""
printf "  ${DIM}Setting up...${RST}\n"

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
      --dangerously-skip-permissions || true
    if [ ! -f "CLAUDE.md" ]; then
      fail "Could not auto-generate CLAUDE.md."
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
      ok "Eval spec ${DIM}(cached)${RST}"
    else
      # Goal changed — re-create eval
      rm -f memory/eval.sh memory/eval-target.txt memory/eval-comparator.txt memory/eval-baseline.txt memory/eval-goal.txt memory/baseline.md
    fi
  fi

  if [ "$NEEDS_EVAL" = true ]; then
    printf "  ${DIM}Creating eval...${RST}\n"
    claude -p "You are preparing a project for an autonomous AI agent loop.

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
   - Complete in under 120 seconds

   Examples of what eval.sh should look like:

   For 'fix all failing tests':
     #!/bin/bash
     pytest --tb=no -q > /tmp/eval-output.log 2>&1 || true
     grep -oE '[0-9]+ failed' /tmp/eval-output.log | grep -oE '[0-9]+' || echo '0'

   For 'improve test coverage to 80%':
     #!/bin/bash
     pytest --cov --cov-report=term > /tmp/eval-output.log 2>&1 || true
     grep 'TOTAL' /tmp/eval-output.log | grep -oE '[0-9]+%' | grep -oE '[0-9]+' || echo '0'

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
Do NOT start servers or long-running processes." \
      --dangerously-skip-permissions \
      --output-format stream-json --verbose 2>&1 | show_agent_progress || true

    # Verify eval works by running it
    if [ -f "memory/eval.sh" ]; then
      EVAL_RESULT=$(run_eval)
      if [[ "$EVAL_RESULT" =~ ^[0-9.]+$ ]]; then
        echo "$EVAL_RESULT" > memory/eval-baseline.txt
        ok "Eval verified ${DIM}(baseline: ${MAG}$EVAL_RESULT${RST}${DIM})${RST}"
      else
        warn "Eval returned '${RED}$EVAL_RESULT${RST}' — falling back to commit-based tracking"
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

  # Display baseline with progress bar
  if [ -f "memory/eval-baseline.txt" ] && [ -f "memory/eval-target.txt" ]; then
    BASELINE_VAL=$(cat memory/eval-baseline.txt)
    TARGET_VAL=$(cat memory/eval-target.txt)
    COMPARATOR_VAL=$(cat memory/eval-comparator.txt 2>/dev/null || echo ">=")
    echo ""
    printf "  ${DIM}┌─────────────────────────────────────────────┐${RST}\n"
    printf "  ${DIM}│${RST}                                             ${DIM}│${RST}\n"
    printf "  ${DIM}│${RST}   Baseline: ${MAG}${BOLD}%-10s${RST} Target: ${CYAN}${BOLD}%-10s${RST}${DIM}│${RST}\n" "$BASELINE_VAL" "$TARGET_VAL"
    printf "  ${DIM}│${RST}                                             ${DIM}│${RST}\n"
    printf "  ${DIM}│${RST} "
    progress_bar "$BASELINE_VAL" "$TARGET_VAL" "$BASELINE_VAL" "$COMPARATOR_VAL"
    printf "              ${DIM}│${RST}\n"
    printf "  ${DIM}│${RST}                                             ${DIM}│${RST}\n"
    printf "  ${DIM}└─────────────────────────────────────────────┘${RST}\n"
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

printf "  ${DIM}Loop started at $(date +%H:%M) · max %d iterations · %d stalls${RST}\n" "$MAX_ITERATIONS" "$MAX_FAILURES"
if [ "$HAS_EVAL" = true ]; then
  printf "  ${DIM}Eval: ${MAG}%s${DIM} → ${CYAN}%s${RST}\n" "$EVAL_BASELINE" "$EVAL_TARGET"
fi
echo ""

while true; do
  ITERATION=$((ITERATION + 1))
  ITER_START=$(date +%s)
  LAST_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")

  # Safety: max iterations
  if [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
    echo ""
    printf "  ${YELLOW}${BOLD}Max iterations ($MAX_ITERATIONS) reached.${RST}\n"
    break
  fi

  printf "  ${BOLD}═══ Iteration %d ${RST}${DIM}═══════════════════════════════════════ %s${RST}\n" "$ITERATION" "$(date +%H:%M)"
  echo ""

  # Agent works until it exits.
  # stream-json + show_agent_progress: show tool calls in real-time.
  # || true: claude exits non-zero on context overflow or interruption — expected.
  claude -p "$PROMPT" --dangerously-skip-permissions \
    --output-format stream-json --verbose 2>&1 | show_agent_progress || true

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
    printf "  ${DIM}Measuring...${RST}"
    CURRENT_METRIC=$(run_eval)

    if [[ "$CURRENT_METRIC" =~ ^[0-9.]+$ ]]; then
      printf "\r                \r"

      # Calculate delta
      DELTA=""
      DELTA_COLOR="$DIM"
      if [[ "$PREV_METRIC" =~ ^[0-9]+$ ]] && [[ "$CURRENT_METRIC" =~ ^[0-9]+$ ]]; then
        DIFF=$((CURRENT_METRIC - PREV_METRIC))
        if [ "$DIFF" -gt 0 ]; then
          DELTA=" (+$DIFF)"
          DELTA_COLOR="$GREEN"
        elif [ "$DIFF" -lt 0 ]; then
          DELTA=" ($DIFF)"
          DELTA_COLOR="$RED"
        fi
      fi

      # Update trajectory (only if metric changed)
      LAST_IN_TRAJECTORY=$(echo "$TRAJECTORY" | sed 's/.* → //')
      if [ "$CURRENT_METRIC" != "$LAST_IN_TRAJECTORY" ]; then
        TRAJECTORY="${TRAJECTORY} → ${CURRENT_METRIC}"
      fi

      # Log to progress file
      echo "$(date +%H:%M) iteration=$ITERATION metric=$CURRENT_METRIC commits=$COMMIT_COUNT" >> memory/progress.log

      # Display result
      if [ "$COMMIT_COUNT" -gt 0 ]; then
        printf "  ${GREEN}✓ ${BOLD}%d commit(s)${RST} · ${MAG}%s${RST}${DELTA_COLOR}%s${RST}    ${DIM}%s${RST}\n" "$COMMIT_COUNT" "$CURRENT_METRIC" "$DELTA" "$ITER_TIME"
      else
        printf "  ${YELLOW}· no commits${RST} · ${MAG}%s${RST}${DELTA_COLOR}%s${RST}    ${DIM}%s${RST}\n" "$CURRENT_METRIC" "$DELTA" "$ITER_TIME"
      fi

      # Progress bar
      progress_bar "$CURRENT_METRIC" "$EVAL_TARGET" "$EVAL_BASELINE" "$EVAL_COMPARATOR"
      echo ""

      # Goal achieved?
      if check_goal "$CURRENT_METRIC" "$EVAL_COMPARATOR" "$EVAL_TARGET"; then
        echo ""
        break
      fi

      # Stall detection (metric unchanged = stall)
      if [ "$CURRENT_METRIC" = "$PREV_METRIC" ]; then
        FAILURES=$((FAILURES + 1))
        if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
          echo ""
          printf "  ${YELLOW}${BOLD}Stalled at %s${RST} ${DIM}(target: %s, %d/%d stalls)${RST}\n" "$CURRENT_METRIC" "$EVAL_TARGET" "$FAILURES" "$MAX_FAILURES"
          break
        else
          printf "  ${DIM}stall %d/%d${RST}\n" "$FAILURES" "$MAX_FAILURES"
        fi
      else
        FAILURES=0
      fi
      PREV_METRIC="$CURRENT_METRIC"

    else
      printf "\r                \r"
      # Eval failed this iteration — fall back to commit-based
      if [ "$COMMIT_COUNT" -gt 0 ]; then
        printf "  ${GREEN}✓ ${BOLD}%d commit(s)${RST} ${DIM}(eval unavailable)${RST}    ${DIM}%s${RST}\n" "$COMMIT_COUNT" "$ITER_TIME"
        FAILURES=0
      else
        FAILURES=$((FAILURES + 1))
        printf "  ${YELLOW}· no changes${RST} ${DIM}(%d/%d)${RST}    ${DIM}%s${RST}\n" "$FAILURES" "$MAX_FAILURES" "$ITER_TIME"
        if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
          echo ""
          printf "  ${YELLOW}${BOLD}Stuck.${RST} No progress in %d iterations.\n" "$MAX_FAILURES"
          break
        fi
      fi
    fi

  else
    # No eval — commit-based progress detection
    if [ "$COMMIT_COUNT" -gt 0 ]; then
      printf "  ${GREEN}✓ ${BOLD}%d commit(s)${RST}    ${DIM}%s${RST}\n" "$COMMIT_COUNT" "$ITER_TIME"
      FAILURES=0
    else
      FAILURES=$((FAILURES + 1))
      printf "  ${YELLOW}· no changes${RST} ${DIM}(%d/%d)${RST}    ${DIM}%s${RST}\n" "$FAILURES" "$MAX_FAILURES" "$ITER_TIME"
      if [ "$FAILURES" -ge "$MAX_FAILURES" ]; then
        echo ""
        printf "  ${YELLOW}${BOLD}Stuck.${RST} No progress in %d iterations.\n" "$MAX_FAILURES"
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
  GOAL_MET=false
  if [[ "$FINAL_METRIC" =~ ^[0-9.]+$ ]] && check_goal "$FINAL_METRIC" "$EVAL_COMPARATOR" "$EVAL_TARGET" 2>/dev/null; then
    GOAL_MET=true
  fi

  if [ "$GOAL_MET" = true ]; then
    # ── Celebration ──
    printf "  ${GREEN}${BOLD}╔═══════════════════════════════════════════════════╗${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST}                                                   ${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST}            ${BG_GREEN} ★  GOAL ACHIEVED  ★ ${RST}              ${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST}                                                   ${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST}   ${MAG}%-47s${RST}${GREEN}${BOLD}║${RST}\n" "$TRAJECTORY"
    printf "  ${GREEN}${BOLD}║${RST}                                                   ${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST} "
    progress_bar "$FINAL_METRIC" "$EVAL_TARGET" "$EVAL_BASELINE" "$EVAL_COMPARATOR"
    printf "                    ${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST}                                                   ${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST}   ${CYAN}%s commits · %d iterations · %dm${RST}" "$TOTAL_COMMITS" "$ITERATION" "$TOTAL_MIN"
    # Pad to fill the box
    local_info="${TOTAL_COMMITS} commits · ${ITERATION} iterations · ${TOTAL_MIN}m"
    local_pad=$((47 - ${#local_info}))
    printf "%${local_pad}s" ""
    printf "${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}║${RST}                                                   ${GREEN}${BOLD}║${RST}\n"
    printf "  ${GREEN}${BOLD}╚═══════════════════════════════════════════════════╝${RST}\n"
  else
    # ── Summary box (goal not met) ──
    printf "  ${DIM}┌─────────────────────────────────────────────────┐${RST}\n"
    printf "  ${DIM}│${RST}                                                 ${DIM}│${RST}\n"
    printf "  ${DIM}│${RST}   Before: ${MAG}${BOLD}%-10s${RST} After: ${MAG}${BOLD}%-10s${RST}      ${DIM}│${RST}\n" "$EVAL_BASELINE" "${FINAL_METRIC:-?}"
    printf "  ${DIM}│${RST}   Target: ${CYAN}%-10s${RST}                           ${DIM}│${RST}\n" "$EVAL_TARGET"
    printf "  ${DIM}│${RST}                                                 ${DIM}│${RST}\n"
    printf "  ${DIM}│${RST} "
    progress_bar "${FINAL_METRIC:-0}" "$EVAL_TARGET" "$EVAL_BASELINE" "$EVAL_COMPARATOR"
    printf "                      ${DIM}│${RST}\n"
    printf "  ${DIM}│${RST}                                                 ${DIM}│${RST}\n"
    printf "  ${DIM}└─────────────────────────────────────────────────┘${RST}\n"
  fi

  echo ""
  if [ -n "$TRAJECTORY" ]; then
    printf "  ${BOLD}Progress${RST}  ${MAG}%s${RST}\n" "$TRAJECTORY"
  fi
fi

printf "  ${BOLD}Done${RST} in %d iterations · %s commits · %dm\n" "$ITERATION" "$TOTAL_COMMITS" "$TOTAL_MIN"
echo ""
printf "  ${DIM}Review    git log --oneline${RST}\n"
printf "  ${DIM}Memory    cat memory/failed-experiments.md${RST}\n"
if [ -n "$GOAL" ]; then
  printf "  ${DIM}Resume    ./run.sh \"%s\"${RST}\n" "$GOAL"
fi
echo ""
