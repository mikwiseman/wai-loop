# wai-loop

Run an AI agent in a loop on your project. Describe a goal — it does the rest.

```bash
./run.sh "fix all failing tests"
```

The script analyzes your project, installs dependencies, measures a baseline, and starts an autonomous loop. After each iteration, the script re-measures progress — not the agent. AI proposes changes, deterministic code evaluates them.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mikwiseman/wai-loop/main/run.sh -o run.sh
chmod +x run.sh
```

Requires [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and git.

## Usage

```bash
./run.sh "fix all failing tests"
./run.sh "improve test coverage to 80%"
./run.sh "fix all ESLint warnings"
```

### Overnight

```bash
tmux new -s loop
./run.sh "fix all failing tests"
# Detach: Ctrl+B, D
# Morning: git log --oneline
```

### Stop

Press `Ctrl+C` — the script catches the signal and exits cleanly. All changes are safe in git.

## How it works

### Phase 1 — Environment

Deterministic setup, no AI involved:

1. Checks that Claude Code and git are installed
2. Creates `.gitignore` with safe defaults (before any `git add`)
3. Initializes a git repo if there isn't one
4. Creates `memory/` directory

### Phase 2 — Project Setup

AI-powered, goal-aware:

1. Generates `CLAUDE.md` — project description, tech stack, test commands
2. Installs dependencies (`npm install`, `pip install`, etc.)
3. Creates `memory/eval.sh` — a measurement script tailored to your goal
4. Runs the eval to capture a baseline (e.g., "12 tests failing")
5. Commits all setup artifacts

The eval script is the core of the system. It outputs a single number — the metric that measures progress toward your goal. The shell script runs it after every iteration.

### Phase 3 — Loop

```
  ┌─── Claude Code ─────────────────────┐
  │                                     │
  │  read failed-experiments.md         │
  │  read baseline.md                   │
  │  work toward goal                   │
  │  commit each fix                    │
  │  NEVER STOP                         │
  │                                     │
  └─────────────────────────────────────┘
            ↓ agent exits
  ┌─── run.sh (deterministic) ──────────┐
  │                                     │
  │  run memory/eval.sh                 │
  │  compare metric to baseline         │
  │  goal achieved? → stop (success)    │
  │  metric improved? → continue        │
  │  metric unchanged 3x? → stop        │
  │                                     │
  └─────────────────────────────────────┘
            ↓ restart with fresh context
```

The agent never judges its own work. The eval script does.

## Example output

```
  wai-loop

  Goal  fix all failing tests

  Setting up...
  ✓ Git repo
  ✓ CLAUDE.md
  ✓ Memory initialized
  ✓ Eval verified (baseline: 12)

  ┌─────────────────────────────────────────┐
  │                                         │
  │   Baseline: 12         Target: 0        │
  │                                         │
  └─────────────────────────────────────────┘

  ── Iteration 1 · 14:23 ──────────────────────────────

  [agent works...]

  ✓ 4 commit(s) · metric: 8 (target: 0)    12m 30s

  ── Iteration 2 · 14:36 ──────────────────────────────

  [agent works...]

  ✓ 3 commit(s) · metric: 3 (target: 0)    9m 15s

  ── Iteration 3 · 14:45 ──────────────────────────────

  [agent works...]

  ✓ 2 commit(s) · metric: 0 (target: 0)    7m 40s

  === Goal achieved! (12 → 8 → 3 → 0) ===

  ┌─────────────────────────────────────────┐
  │                                         │
  │   Before: 12         After: 0           │
  │   Target: 0                             │
  │                                         │
  └─────────────────────────────────────────┘

  Progress  12 → 8 → 3 → 0
  Done in 3 iterations · 9 commits · 29m

  Review    git log --oneline
  Memory    cat memory/failed-experiments.md
  Resume    ./run.sh "fix all failing tests"
```

## How memory works

- **`memory/eval.sh`** — measurement script created during setup. Outputs a single number. The shell script runs this after every iteration — the agent never evaluates itself.
- **`memory/eval-target.txt`** — the target metric (e.g., `0` for zero failures).
- **`memory/eval-baseline.txt`** — where you started.
- **`memory/failed-experiments.md`** — approaches that didn't work, with dates and reasons. The agent reads this before each iteration.
- **`memory/successful-approaches.md`** — what worked. Patterns accumulate over runs.
- **`memory/baseline.md`** — human-readable starting state for the agent.
- **`memory/progress.log`** — metric after each iteration (timestamp, iteration, metric, commits).

Between restarts, the agent also sees:
- `CLAUDE.md` — project rules and conventions
- `git log` — what was already done

## How it differs from built-in tools

- **Claude Code `/loop`** — periodic polling (`/loop 5m check deploy`). Great for monitoring. wai-loop is goal-driven with eval-based stopping.
- **Claude Code Auto Memory** — saves general context in `MEMORY.md`. Does not record failed approaches or measure progress toward a goal.
- **Karpathy's autoresearch** — eval-driven loop for ML research. wai-loop applies the same pattern universally: the eval script is auto-generated from your goal.

## Security

The script runs `claude --dangerously-skip-permissions` — the agent can execute any command without confirmation. **Review your `.gitignore` before running.** The script creates safe defaults (`.env*`, `*.pem`, `*.key`), but verify it covers your secrets.

The agent is instructed not to modify `run.sh` or `memory/eval.sh`. The script verifies this with checksums after each iteration and restores them if tampered with.

Do not run on repositories with production credentials or deploy keys that aren't in `.gitignore`.

## Limitations

- Works with Claude Code only (not Codex, Cursor, or other agents)
- Goals should be measurable — "fix all failing tests" works, "make the code better" doesn't
- For qualitative goals (refactor, migrate), falls back to commit-based progress detection
- The agent can make mistakes — always review with `git log` and `git diff` before pushing
- Cost: each iteration ≈ $0.5–2, overnight ≈ $10–50

## Files created

```
your-project/
├── CLAUDE.md                       # Project description (auto-generated)
├── memory/
│   ├── eval.sh                    # Measurement script (auto-generated)
│   ├── eval-target.txt            # Target metric
│   ├── eval-comparator.txt        # Comparison operator
│   ├── eval-baseline.txt          # Starting metric
│   ├── eval-goal.txt              # The goal string
│   ├── baseline.md                # Human-readable baseline
│   ├── progress.log               # Metric per iteration
│   ├── failed-experiments.md      # What didn't work
│   └── successful-approaches.md   # What worked
└── .gitignore                     # Safety patterns
```

## Options

```bash
./run.sh "goal"                     # defaults: 3 stalls, 50 iterations
./run.sh "goal" --max-failures 5    # stop after 5 stalls
./run.sh "goal" --max-iterations 100  # max 100 iterations
./run.sh custom-prompt.md           # use a prompt file (skips eval setup)
```

## Credits

- [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) — the eval-driven loop pattern
- [Ralph Wiggum Loop](https://github.com/nearestnabors/ralph-wiggum-loop-starter) — the external restart pattern
- [Ian Paterson](https://ianlpaterson.com/blog/claude-code-memory-architecture/) — memory architecture principles
