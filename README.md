# wai-loop

Universal agent loop with memory. Inspired by [Karpathy's autoresearch](https://github.com/karpathy/autoresearch), adapted for any project.

**autoresearch** runs an agent that optimizes neural network training in a loop. **wai-loop** takes the same pattern — agent works, checks result, keeps or discards, remembers failures — and makes it work for tests, refactoring, performance, coverage, or any task with a measurable outcome.

## What's different from autoresearch

| autoresearch | wai-loop |
|---|---|
| One metric (val_bpb) | Any metric (tests, coverage, perf) |
| One file (train.py) | Any project scope |
| No failure memory | `memory/failed-experiments.md` — agent reads before each iteration |
| No success log | `memory/successful-fixes.md` — patterns accumulate |
| ML only | Universal |
| No progress detection | Script checks HEAD before/after, stops if stuck |

## How it works

```
┌─────────────────────────────┐
│         run.sh              │  ← outer loop (safety net)
│  saves HEAD, starts agent   │
│                             │
│  ┌───────────────────────┐  │
│  │     Claude Code       │  │  ← inner loop (NEVER STOP)
│  │                       │  │
│  │  read failed-exp.md   │  │
│  │  run tests            │  │
│  │  fix first failure    │  │
│  │  run tests again      │  │
│  │  pass → commit         │  │
│  │  fail → try another    │  │
│  │  write to memory       │  │
│  │  NEVER STOP            │  │
│  └───────────────────────┘  │
│                             │
│  agent exited               │
│  check: new commits?        │
│  yes → restart with fresh   │
│         context             │
│  no (3x) → stop            │
└─────────────────────────────┘
```

**NEVER STOP** is the work ethic — the agent keeps going after each fix instead of stopping.
**run.sh** is the safety net — if the agent crashes or hits context limits, the script restarts it with a clean context window.
**Memory files** are the brain — the agent reads what failed before and doesn't repeat it.

## Quick start

### Option 1: Setup script (existing project)

In your project directory:

```bash
curl -fsSL https://raw.githubusercontent.com/mikwiseman/wai-loop/main/setup.sh | bash
```

This creates `memory/`, downloads `run.sh` and `PROMPT.md`, and adds memory instructions to your `CLAUDE.md`.

### Option 2: Manual setup

```bash
# 1. Clone examples
git clone https://github.com/mikwiseman/wai-loop.git
cp wai-loop/run.sh your-project/
cp wai-loop/PROMPT.md your-project/
cp -r wai-loop/memory your-project/
chmod +x your-project/run.sh

# 2. Add to your CLAUDE.md
echo "Before starting work, read memory/failed-experiments.md — do not repeat failed approaches." >> your-project/CLAUDE.md

# 3. Add *.log to .gitignore
echo "*.log" >> your-project/.gitignore

# 4. Edit PROMPT.md for your project
# Change the test command, grep pattern, etc.

# 5. Run
cd your-project
tmux new -s loop
./run.sh
```

### Option 3: Just the prompt (simplest)

No script needed. Open `claude --dangerously-skip-permissions` in your project and paste:

```
Read memory/failed-experiments.md — do not repeat failed approaches.

Run tests: npm test > test.log 2>&1
Read result: grep -iE "FAIL|ERROR|failed|failing" test.log

Fix the first failing test. Run again. Pass — commit. Fail — try another way.
Failed approach — write to memory/failed-experiments.md with date.
All output to files, read only grep.

NEVER STOP.
```

This works for ~30-60 minutes before context degrades. For overnight runs, use `run.sh`.

## Example prompts

| File | Task |
|---|---|
| `examples/fix-tests.md` | Fix all failing tests (Node.js) |
| `examples/python-fix-tests.md` | Fix all failing tests (Python/pytest) |
| `examples/improve-coverage.md` | Improve test coverage |
| `examples/optimize-perf.md` | Optimize performance (benchmark loop) |

Copy one to `PROMPT.md` and edit for your project:

```bash
cp examples/fix-tests.md PROMPT.md
# Edit test command, grep pattern, etc.
```

## Project structure

```
your-project/
├── CLAUDE.md                  # Project rules (created by /init)
│                              # + memory instruction pointing to failed-experiments.md
├── PROMPT.md                  # Task for the agent (you write)
├── run.sh                     # Loop script (from wai-loop)
├── .gitignore                 # Must include *.log
└── memory/
    ├── failed-experiments.md  # What didn't work (agent writes)
    └── successful-fixes.md   # What worked (agent writes)
```

## How memory works

**Between iterations** (when run.sh restarts the agent):
- Agent reads `memory/failed-experiments.md` → knows what not to repeat
- Agent reads `memory/successful-fixes.md` → knows what patterns work
- Agent reads `CLAUDE.md` → knows project rules and constraints
- Agent sees current code and `git log` → knows what's already done

**Within an iteration** (while NEVER STOP is running):
- Agent keeps full conversation context
- All command output goes to files (`> log 2>&1`), only grep results enter context
- This keeps the context clean for hours — [the key trick from Karpathy](https://github.com/karpathy/autoresearch/blob/master/program.md)

**Why failed-experiments.md is the most important file:**
Without it, the agent [rediscovers the same failures](https://github.com/karpathy/autoresearch/issues/179) every iteration. With it, each iteration starts smarter than the last.

## Configuration

Edit `run.sh` variables or pass arguments:

```bash
./run.sh                     # defaults: PROMPT.md, max 3 failures
./run.sh my-prompt.md        # custom prompt
./run.sh PROMPT.md 5         # max 5 failures before stopping
```

Run in tmux so it survives terminal disconnect:

```bash
tmux new -s loop
./run.sh
# Detach: Ctrl+B, then D
# Reattach: tmux attach -t loop
# Morning: git log --oneline
```

## Cost

Each iteration costs roughly what a single Claude Code session costs ($0.5–2 depending on task complexity). An overnight run of 20-30 iterations: $10-50.

To limit spend, use `--max-budget-usd` in run.sh:
```bash
claude -p "$(cat "$PROMPT_FILE")" \
  --dangerously-skip-permissions \
  --max-budget-usd 5
```

## Credits

- [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) — the original pattern
- [Ralph Wiggum Loop](https://github.com/nearestnabors/ralph-wiggum-loop-starter) — the external restart pattern
- [Ian Paterson's memory architecture](https://ianlpaterson.com/blog/claude-code-memory-architecture/) — memory system principles
