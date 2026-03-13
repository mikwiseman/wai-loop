Read memory/failed-experiments.md — do not repeat failed approaches.

Run tests: npm test > test.log 2>&1
Read result: grep -iE "FAIL|ERROR|failed|failing" test.log

Find the first failing test. Fix it. Run tests again.
Green — git commit with description. Red — different approach.

Failed approach — write to memory/failed-experiments.md with date and reason.
Successful fix — write to memory/successful-fixes.md with date.

All output to files. Read only grep results. Never dump full logs.

NEVER STOP. Move to the next failing test.
