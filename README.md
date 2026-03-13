# wai-loop

Run an AI agent in a loop on your project. Describe a goal — the agent works toward it, remembers what didn't work, and keeps going.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/mikwiseman/wai-loop/main/run.sh -o run.sh && chmod +x run.sh

./run.sh "fix all failing tests"
```

That's it. First run creates memory files automatically. The agent reads your project, works toward the goal, commits each fix, and loops until done or stuck.

Requires [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Examples

```bash
./run.sh "fix all failing tests"
./run.sh "improve test coverage to 80%"
./run.sh "optimize the slowest API endpoint"
./run.sh "fix all ESLint warnings"
./run.sh "migrate from CommonJS to ES modules"
./run.sh "refactor all callbacks to async/await"
./run.sh "add input validation to all API routes"
```

## How it works

You describe a goal in plain language. The script:

1. Wraps your goal with instructions for memory and output discipline
2. Starts Claude Code with the prompt
3. The agent works autonomously — fixing, testing, committing
4. When the agent exits (finished, crashed, or context full), the script checks: were there new commits?
5. Yes → restart with fresh context, agent picks up where it left off
6. No, three times → stop (to avoid burning money on a stuck agent)

```
You: ./run.sh "fix all failing tests"

  ┌─── run.sh (outer loop) ──────────────────┐
  │                                           │
  │  ┌─── Claude Code (inner loop) ────────┐  │
  │  │                                     │  │
  │  │  read memory/failed-experiments.md  │  │
  │  │  figure out the next step           │  │
  │  │  run command > result.log           │  │
  │  │  grep result.log for summary        │  │
  │  │  worked → git commit                │  │
  │  │  failed → write to failed-exp.md    │  │
  │  │  NEVER STOP                         │  │
  │  │                                     │  │
  │  └─────────────────────────────────────┘  │
  │                                           │
  │  agent exited → new commits? → restart    │
  │  no progress 3x → stop                   │
  └───────────────────────────────────────────┘
```

### Why NEVER STOP works

The agent is told to redirect all output to files and read only grep results. Instead of thousands of log lines filling up its working memory, it sees one summary line. This keeps the context clean for much longer.

When the context eventually fills up, the agent exits, and `run.sh` restarts it fresh. The agent re-reads the project files and memory, sees the commits from previous iterations, and continues.

### Why memory matters

Without `memory/failed-experiments.md`, the agent rediscovers the same failures every iteration. With it, each restart is smarter than the last.

## What gets created

On first run, `run.sh` automatically creates:

```
your-project/
├── memory/
│   ├── failed-experiments.md    # What didn't work (agent writes)
│   └── successful-approaches.md # What worked (agent writes)
└── .gitignore                   # *.log added if missing
```

If you have a `CLAUDE.md` (project rules for Claude Code), the script adds memory instructions to it.

## Options

```bash
./run.sh "goal"                    # default: 3 failures before stop
./run.sh "goal" --max-failures 5   # custom limit
./run.sh my-prompt.md              # advanced: use a prompt file
```

### Custom prompt files

For full control, write a `.md` file and pass it instead of a goal string:

```bash
./run.sh my-task.md
```

The file should contain the complete prompt. Include `NEVER STOP` and output-to-file instructions.

### Running overnight

Use tmux so the loop survives terminal disconnect:

```bash
tmux new -s loop
./run.sh "fix all failing tests"
# Detach: Ctrl+B, then D
# Morning: tmux attach -t loop
# Or just: git log --oneline
```

## Cost

Each iteration ≈ $0.5–2 depending on task complexity. Overnight (20-30 iterations) ≈ $10–50.

## How is this different from autoresearch?

[Karpathy's autoresearch](https://github.com/karpathy/autoresearch) optimizes neural network training in a loop. Same core idea (agent works → checks result → keeps or discards → repeats), but:

- **autoresearch**: one metric, one file, ML only, no failure memory
- **wai-loop**: any goal, any project, remembers what didn't work

## Credits

- [Karpathy's autoresearch](https://github.com/karpathy/autoresearch) — the original pattern
- [Ralph Wiggum Loop](https://github.com/nearestnabors/ralph-wiggum-loop-starter) — the external restart pattern
- [Ian Paterson](https://ianlpaterson.com/blog/claude-code-memory-architecture/) — memory architecture principles
