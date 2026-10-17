-- e2e: 6000 rows across several fetch batches and DuckDB vectors (2048 rows each), no row lost or reordered
-- timeout: 180
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  CAST(LEVEL AS NUMBER(10))              AS n,
  ''row '' || LEVEL                      AS s,
  TO_DATE(''2020-01-01'', ''YYYY-MM-DD'') + LEVEL AS d
FROM dual CONNECT BY LEVEL <= 6000');
CREATE TEMP TABLE checks AS
SELECT '6000 rows' AS name, count(*) = 6000 AS ok FROM r
UNION ALL SELECT 'sum(n) = 18003000', sum(n) = 18003000 FROM r
UNION ALL SELECT 'n runs from 1 to 6000', min(n) = 1 AND max(n) = 6000 FROM r
UNION ALL SELECT '6000 distinct strings', count(DISTINCT s) = 6000 FROM r
UNION ALL SELECT 'strings belong to their numbers', count(*) FILTER (WHERE s = 'row ' || n) = 6000 FROM r
UNION ALL SELECT 'dates belong to their numbers', count(*) FILTER (WHERE d = TIMESTAMP '2020-01-01' + to_days(n::INTEGER)) = 6000 FROM r
UNION ALL SELECT 'rows around the first vector boundary (2047..2050)', list(n ORDER BY n) = [2047, 2048, 2049, 2050] FROM r WHERE n BETWEEN 2047 AND 2050
UNION ALL SELECT 'rows around the second vector boundary (4095..4098)', list(n ORDER BY n) = [4095, 4096, 4097, 4098] FROM r WHERE n BETWEEN 4095 AND 4098
UNION ALL SELECT 'the last row', max(s) FILTER (WHERE n = 6000) = 'row 6000' FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
