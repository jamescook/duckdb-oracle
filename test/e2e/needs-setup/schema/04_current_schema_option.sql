-- e2e: current_schema := 'X' on oracle_query runs ALTER SESSION SET CURRENT_SCHEMA for that connection only
-- (needs test/e2e/setup/common/00_schema.sql)
-- timeout: 120
CREATE TEMP TABLE switched AS SELECT * FROM oracle_query('@DSN@',
  'SELECT COUNT(*) AS n, SYS_CONTEXT(''USERENV'', ''CURRENT_SCHEMA'') AS cs, SYS_CONTEXT(''USERENV'', ''SESSION_USER'') AS su FROM people',
  current_schema := 'e2e_owner');
CREATE TEMP TABLE quoted AS SELECT * FROM oracle_query('@DSN@', 'SELECT SYS_CONTEXT(''USERENV'', ''CURRENT_SCHEMA'') AS cs FROM dual', current_schema := '"E2E_OWNER"');
CREATE TEMP TABLE bare_quoted AS SELECT * FROM oracle_query('@DSN@', 'SELECT COUNT(*) AS n FROM "MixedCase"', current_schema := 'e2e_owner');
CREATE TEMP TABLE plain AS SELECT * FROM oracle_query('@DSN@',
  'SELECT SYS_CONTEXT(''USERENV'', ''CURRENT_SCHEMA'') AS cs, SYS_CONTEXT(''USERENV'', ''SESSION_USER'') AS su FROM dual');
CREATE TEMP TABLE null_option AS SELECT * FROM oracle_query('@DSN@',
  'SELECT SYS_CONTEXT(''USERENV'', ''CURRENT_SCHEMA'') AS cs, SYS_CONTEXT(''USERENV'', ''SESSION_USER'') AS su FROM dual', current_schema := NULL);
CREATE TEMP TABLE checks AS
SELECT 'bare name resolved in the other schema' AS name, n = 3 AS ok FROM switched
UNION ALL SELECT 'the current schema is the one asked for', cs = 'E2E_OWNER' FROM switched
UNION ALL SELECT 'the session user is not changed', su != 'E2E_OWNER' FROM switched
UNION ALL SELECT 'a quoted schema name is taken exactly', cs = 'E2E_OWNER' FROM quoted
UNION ALL SELECT 'a bare quoted table name in that schema', n = 2 FROM bare_quoted
UNION ALL SELECT 'without the option the current schema is the session user', cs = su FROM plain
UNION ALL SELECT 'a NULL current_schema leaves it alone', cs = su FROM null_option
UNION ALL SELECT 'the option does not leak into the next connection', (SELECT cs FROM plain) != 'E2E_OWNER';

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
