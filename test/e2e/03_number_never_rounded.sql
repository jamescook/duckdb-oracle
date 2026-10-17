-- e2e: an integer a DOUBLE cannot hold exactly is an error, never silently rounded
-- expect-error: cannot be represented exactly as DOUBLE
-- expect-error: 9007199254740993
-- expect-output: process-still-running
.bail off
-- 2^53 + 1, in an expression, so Oracle reports it as an unconstrained NUMBER
SELECT * FROM oracle_query('@DSN@', 'SELECT 9007199254740993 * COUNT(*) AS big FROM dual');
-- the process is still running and Oracle is still usable
SELECT 'process-still-running' AS status;
