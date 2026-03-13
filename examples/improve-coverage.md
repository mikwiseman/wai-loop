Read memory/failed-experiments.md — do not repeat failed approaches.

Run coverage: npm test -- --coverage > coverage.log 2>&1
Read result: grep -E "Stmts|Lines|Branch" coverage.log

Find the file with the lowest coverage. Write tests for uncovered paths.

Run tests again: npm test > test.log 2>&1
Read: grep -iE "FAIL|ERROR|failed|failing" test.log

All pass and coverage improved — git commit.
Tests fail — fix or revert.
Coverage didn't improve — write to memory/failed-experiments.md with date.

All output to files. Read only grep results.

NEVER STOP. Move to the next file with low coverage.
