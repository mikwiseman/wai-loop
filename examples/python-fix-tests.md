Read memory/failed-experiments.md — do not repeat failed approaches.

Run tests: python -m pytest > test.log 2>&1
Read result: grep -E "FAILED|ERROR|passed|failed" test.log

Find the first failing test. Fix it. Run tests again.
All pass — git commit with description. Failures remain — different approach.

Failed approach — write to memory/failed-experiments.md with date and reason.
Successful fix — write to memory/successful-fixes.md with date.

All output to files. Read only grep results.

NEVER STOP. Move to the next failing test.
