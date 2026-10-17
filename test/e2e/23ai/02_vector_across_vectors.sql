-- e2e: 3000 VECTOR rows (two DuckDB chunks): list offsets must stay correct across chunks
-- (Run only against a 23ai/26ai server with a 23ai+ client.)
-- timeout: 180
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@',
  'SELECT TO_VECTOR(''['' || LEVEL || '','' || (2 * LEVEL) || '']'', 2, FLOAT32) AS v FROM dual CONNECT BY LEVEL <= 3000');
CREATE TEMP TABLE checks AS
SELECT '3000 rows' AS name, count(*) = 3000 AS ok FROM r
UNION ALL SELECT 'every vector has 2 elements', count(*) FILTER (WHERE len(v) = 2) = 3000 FROM r
UNION ALL SELECT 'first elements sum to 4501500', sum(v[1]) = 4501500 FROM r
UNION ALL SELECT 'second elements sum to 9003000', sum(v[2]) = 9003000 FROM r
UNION ALL SELECT 'the second element is twice the first', count(*) FILTER (WHERE v[2] = 2 * v[1]) = 3000 FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
