Read memory/failed-experiments.md — these are approaches that already failed. Do not repeat them.

Run tests: npm test > test.log 2>&1
Read result: grep -iE "FAIL|ERROR|failed|failing" test.log

Find the first failing test. Fix it. Run tests again.

If all pass — git commit with a description of what you fixed.
If not — try a different approach.

If an approach did not work — write it to memory/failed-experiments.md with the date and reason.
If an approach worked — write a short note to memory/successful-fixes.md with the date.

All command output goes to files. Read only the relevant lines via grep.
Never dump full logs into context.

NEVER STOP. Move to the next failing test.
