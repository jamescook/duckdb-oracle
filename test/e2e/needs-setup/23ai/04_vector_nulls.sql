-- e2e: NULL VECTORs: a whole NULL row, NULLs between values, and a column that is NULL in every row
-- (needs test/e2e/setup/23ai/00_vectors.sql, and a 23ai+ server AND client)
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT * FROM e2e_vectors ORDER BY id');
CREATE TEMP TABLE only_null AS SELECT * FROM oracle_query('@DSN@', 'SELECT v32, vflex FROM e2e_vectors WHERE id = 2');
CREATE TEMP TABLE sandwich AS SELECT * FROM oracle_query('@DSN@', 'SELECT id, v32 FROM e2e_vectors WHERE id IN (1, 2, 3) ORDER BY id');
CREATE TEMP TABLE checks AS
SELECT 'every vector column of the NULL row is NULL' AS name,
       v32 IS NULL AND v64 IS NULL AND v8 IS NULL AND vflex IS NULL AND vdim IS NULL AND vfmt IS NULL AS ok FROM r WHERE id = 2
UNION ALL SELECT 'the other rows are not NULL', count(*) FILTER (WHERE v32 IS NOT NULL AND vflex IS NOT NULL) = 3 FROM r
UNION ALL SELECT 'a NULL between two vectors does not disturb their values',
       list(v32 ORDER BY id) = [[1.5, 2, 3]::FLOAT[], NULL, [-1, 0, 1]::FLOAT[]] FROM sandwich
UNION ALL SELECT 'a result that is only NULL keeps the list type', count(*) = 1 AND count(v32) = 0 AND count(vflex) = 0
       AND typeof(any_value(v32)) = 'FLOAT[]' AND typeof(any_value(vflex)) = 'DOUBLE[]' FROM only_null;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
