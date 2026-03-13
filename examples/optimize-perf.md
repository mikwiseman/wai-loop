Read memory/failed-experiments.md — do not repeat failed approaches.

Run benchmark: npm run bench > bench.log 2>&1
Read result: grep -E "ops/sec|time|latency|Requests" bench.log
Save baseline number.

Identify the slowest path. Optimize it.

Run tests: npm test > test.log 2>&1
Read: grep -iE "FAIL|ERROR|failed|failing" test.log

Tests pass — run benchmark again.
Faster — git commit with before/after numbers.
Slower or tests fail — git checkout . (revert changes).

Write every attempt to memory/failed-experiments.md (if slower) or memory/successful-fixes.md (if faster) with date and numbers.

All output to files. Read only grep results.

NEVER STOP. Move to the next bottleneck.
