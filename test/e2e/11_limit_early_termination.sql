-- e2e: LIMIT stops a 100-million-row query early, repeatedly (each run opens and must release its own session)
-- timeout: 240
CREATE TEMP TABLE checks AS
SELECT 'LIMIT 3 run 1' AS name, count(*) = 3 AS ok FROM (SELECT * FROM oracle_query('@DSN@', 'SELECT CAST(LEVEL AS NUMBER(18)) AS n FROM dual CONNECT BY LEVEL <= 100000000') LIMIT 3)
UNION ALL SELECT 'LIMIT 3 run 2' AS name, count(*) = 3 AS ok FROM (SELECT * FROM oracle_query('@DSN@', 'SELECT CAST(LEVEL AS NUMBER(18)) AS n FROM dual CONNECT BY LEVEL <= 100000000') LIMIT 3)
UNION ALL SELECT 'LIMIT 3 run 3' AS name, count(*) = 3 AS ok FROM (SELECT * FROM oracle_query('@DSN@', 'SELECT CAST(LEVEL AS NUMBER(18)) AS n FROM dual CONNECT BY LEVEL <= 100000000') LIMIT 3)
UNION ALL SELECT 'LIMIT 3 run 4' AS name, count(*) = 3 AS ok FROM (SELECT * FROM oracle_query('@DSN@', 'SELECT CAST(LEVEL AS NUMBER(18)) AS n FROM dual CONNECT BY LEVEL <= 100000000') LIMIT 3)
UNION ALL SELECT 'LIMIT 3 run 5' AS name, count(*) = 3 AS ok FROM (SELECT * FROM oracle_query('@DSN@', 'SELECT CAST(LEVEL AS NUMBER(18)) AS n FROM dual CONNECT BY LEVEL <= 100000000') LIMIT 3)
UNION ALL SELECT 'LIMIT 1 returns the first row', min(n) = 1 FROM (SELECT * FROM oracle_query('@DSN@',
  'SELECT CAST(LEVEL AS NUMBER(18)) AS n FROM dual CONNECT BY LEVEL <= 100000000') LIMIT 1)
UNION ALL SELECT 'LIMIT 0 returns nothing', count(*) = 0 FROM (SELECT * FROM oracle_query('@DSN@',
  'SELECT CAST(LEVEL AS NUMBER(18)) AS n FROM dual CONNECT BY LEVEL <= 100000000') LIMIT 0)
UNION ALL SELECT 'the connection still works afterwards', count(*) = 1 FROM oracle_query('@DSN@', 'SELECT 1 FROM dual');

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
