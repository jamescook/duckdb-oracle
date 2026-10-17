-- e2e: SELECT * FROM dual
-- Conventions (see test-windows.ps1, Invoke-E2ESuite):
--   @DSN@ is replaced by the Oracle connect string; the login comes from ORACLE_USER / ORACLE_PASSWORD
--   in the environment, never from SQL. The runner LOADs the extension before running this file.
--   A file passes if DuckDB exits 0; a failed check calls error(), which fails the run with its name.

CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT * FROM dual');
SELECT * FROM r;
CREATE TEMP TABLE checks AS
SELECT 'one row' AS name, count(*) = 1 AS ok FROM r
UNION ALL SELECT 'DUMMY = X', min(dummy) = 'X' FROM r
UNION ALL SELECT 'DUMMY is VARCHAR', typeof(any_value(dummy)) = 'VARCHAR' FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
