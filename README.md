# wai-loop

Run an AI agent in a loop on your project. Describe a goal — it does the rest.

```bash
./run.sh "fix all failing tests"
```

The script analyzes your project, sets up memory files, and starts an autonomous loop. The agent works toward your goal, commits each fix, remembers what didn't work, and keeps going.

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
./run.sh "optimize the slowest API endpoint"
./run.sh "fix all ESLint warnings"
./run.sh "migrate from CommonJS to ES modules"
./run.sh "refactor all callbacks to async/await"
./run.sh "add input validation to all API routes"
```

### Overnight

```bash
tmux new -s loop
./run.sh "fix all failing tests"
# Detach: Ctrl+B, D
# Morning: git log --oneline
```

## What happens when you run it

**First run** — automatic setup:

1. Checks that Claude Code and git are installed
2. Initializes a git repo if there isn't one
3. Generates `CLAUDE.md` — the agent analyzes your project and writes a description (tech stack, conventions, how to run tests)
4. Creates `memory/` with `failed-experiments.md` and `successful-approaches.md`
5. Adds `*.log` to `.gitignore`
6. Starts the loop

**Every run** — the loop:

1. Your goal is wrapped with instructions for memory and output discipline
2. The agent works autonomously: analyzing, fixing, testing, committing
3. When the agent exits (finished, crashed, or context full), the script checks for new commits
4. New commits → restart with fresh context. The agent re-reads memory and continues
5. No progress 3 times in a row → stop

```
./run.sh "fix all failing tests"

  ┌─── run.sh ────────────────────────────────┐
  │                                            │
  │  ┌─── Claude Code ─────────────────────┐   │
  │  │                                     │   │
  │  │  read failed-experiments.md         │   │
  │  │  figure out next step               │   │
  │  │  run command > result.log           │   │
  │  │  grep result.log                    │   │
  │  │  worked → git commit                │   │
  │  │  failed → write to memory           │   │
  │  │  NEVER STOP                         │   │
  │  │                                     │   │
  │  └─────────────────────────────────────┘   │
  │                                            │
  │  new commits? → restart                    │
  │  stuck 3x? → stop                         │
  └────────────────────────────────────────────┘
```

## How memory works

The agent keeps two files:

- **`memory/failed-experiments.md`** — approaches that didn't work, with dates and reasons. The agent reads this before each iteration and doesn't repeat mistakes.
- **`memory/successful-approaches.md`** — approaches that worked. Patterns accumulate over runs.

Between restarts, the agent also sees:
- `CLAUDE.md` — project rules and conventions
- `git log` — what was already done
- Current code — the state of the project

Each iteration starts smarter than the last.

## Files created

```
your-project/
├── CLAUDE.md                       # Project description (auto-generated)
├── run.sh                          # This script
├── memory/
│   ├── failed-experiments.md       # What didn't work
│   └── successful-approaches.md    # What worked
└── .gitignore                      # *.log added
```

## Options

```bash
./run.sh "goal"                     # 3 failures = stop (default)
./run.sh "goal" --max-failures 5    # 5 failures = stop
./run.sh custom-prompt.md           # use a prompt file instead of a goal
```

## Cost

Each restart ≈ $0.5–2 depending on complexity. Overnight (20-30 iterations) ≈ $10–50.

## Credits

- [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) — the original loop pattern
- [Ralph Wiggum Loop](https://github.com/nearestnabors/ralph-wiggum-loop-starter) — the external restart pattern
- [Ian Paterson](https://ianlpaterson.com/blog/claude-code-memory-architecture/) — memory architecture principles
