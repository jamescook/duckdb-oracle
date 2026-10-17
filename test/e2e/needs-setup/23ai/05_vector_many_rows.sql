-- e2e: 2500 VECTOR rows (more than one DuckDB vector): fixed 4-dimension FLOAT32 with a NULL every 7th row, and a flexible
-- column whose length changes from row to row (1, 2 or 3 elements), so list offsets must stay right across chunk boundaries
-- (needs test/e2e/setup/23ai/00_vectors.sql, and a 23ai+ server AND client)
-- timeout: 180
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT id, v, w FROM e2e_vectors_many ORDER BY id');
CREATE TEMP TABLE checks AS
SELECT '2500 rows' AS name, count(*) = 2500 AS ok FROM r
UNION ALL SELECT 'v is FLOAT[] and w is DOUBLE[]', typeof(any_value(v)) = 'FLOAT[]' AND typeof(any_value(w)) = 'DOUBLE[]' FROM r
UNION ALL SELECT 'v is NULL exactly in every 7th row (357 rows)', count(*) FILTER (WHERE v IS NULL) = 357 AND count(*) FILTER (WHERE v IS NULL AND id % 7 != 0) = 0 FROM r
UNION ALL SELECT 'every non-NULL v has 4 elements', count(*) FILTER (WHERE v IS NOT NULL AND len(v) = 4) = 2143 FROM r
UNION ALL SELECT 'v[1] is the id', count(*) FILTER (WHERE v IS NOT NULL AND v[1] = id) = 2143 FROM r
UNION ALL SELECT 'v[2] is 2*id and v[3] is 3*id', count(*) FILTER (WHERE v IS NOT NULL AND v[2] = 2 * id AND v[3] = 3 * id) = 2143 FROM r
UNION ALL SELECT 'v[4] is id mod 5', count(*) FILTER (WHERE v IS NOT NULL AND v[4] = id % 5) = 2143 FROM r
UNION ALL SELECT 'sum of v[1] over the non-NULL rows', sum(v[1]) = 2678929 FROM r
UNION ALL SELECT 'w has 1 + id mod 3 elements in every row', count(*) FILTER (WHERE len(w) = 1 + id % 3) = 2500 FROM r
UNION ALL SELECT 'every element of w is the id', count(*) FILTER (WHERE list_min(w) = id AND list_max(w) = id) = 2500 FROM r
UNION ALL SELECT 'w across the first vector boundary (ids 2047..2050 have 2, 3, 1 and 2 elements)',
       list(w ORDER BY id) = [[2047, 2047], [2048, 2048, 2048], [2049], [2050, 2050]]::DOUBLE[][] FROM r WHERE id BETWEEN 2047 AND 2050;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
