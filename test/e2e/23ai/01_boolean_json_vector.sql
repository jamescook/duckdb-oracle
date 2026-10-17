-- e2e: Oracle 23ai/26ai types: BOOLEAN, JSON and VECTOR (needs a 23ai+ server AND a 23ai+ Oracle client)
-- (Run by test-windows.ps1 only against the optional 23ai/26ai database, and only if the loaded client is 23 or newer.)
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  TRUE                                                AS b_true,
  FALSE                                               AS b_false,
  CAST(NULL AS BOOLEAN)                               AS b_null,
  JSON(''{"a":1,"b":[true,null,"x"],"c":{"d":1.5}}'')   AS j,
  CAST(NULL AS JSON)                                  AS j_null,
  TO_VECTOR(''[1.5,2,3]'', 3, FLOAT32)                  AS v32,
  TO_VECTOR(''[1.5,2,3]'', 3, FLOAT64)                  AS v64,
  TO_VECTOR(''[1,-2,3]'', 3, INT8)                      AS vi8,
  CAST(NULL AS VECTOR(3, FLOAT32))                    AS v_null
FROM dual');
DESCRIBE SELECT * FROM r;
SELECT * FROM r;
CREATE TEMP TABLE checks AS
SELECT 'BOOLEAN true' AS name, b_true = true AS ok FROM r
UNION ALL SELECT 'BOOLEAN false', b_false = false FROM r
UNION ALL SELECT 'BOOLEAN NULL', b_null IS NULL FROM r
UNION ALL SELECT 'JSON number', json_extract(j, '$.a')::INTEGER = 1 FROM r
UNION ALL SELECT 'JSON string in array', json_extract_string(j, '$.b[2]') = 'x' FROM r
UNION ALL SELECT 'JSON boolean in array', json_extract(j, '$.b[0]')::BOOLEAN = true FROM r
UNION ALL SELECT 'JSON nested number', json_extract(j, '$.c.d')::DOUBLE = 1.5 FROM r
UNION ALL SELECT 'JSON NULL', j_null IS NULL FROM r
UNION ALL SELECT 'VECTOR FLOAT32 is FLOAT[]', typeof(v32) = 'FLOAT[]' FROM r
UNION ALL SELECT 'VECTOR FLOAT32 values', v32 = [1.5, 2, 3]::FLOAT[] FROM r
UNION ALL SELECT 'VECTOR FLOAT64 is DOUBLE[]', typeof(v64) = 'DOUBLE[]' FROM r
UNION ALL SELECT 'VECTOR FLOAT64 values', v64 = [1.5, 2, 3]::DOUBLE[] FROM r
UNION ALL SELECT 'VECTOR INT8 values', vi8 = [1, -2, 3]::FLOAT[] FROM r
UNION ALL SELECT 'VECTOR NULL', v_null IS NULL FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
