-- e2e: VECTOR columns with declared types: FLOAT32 -> FLOAT[], FLOAT64 -> DOUBLE[], INT8 -> FLOAT[], flexible -> as documented
-- (needs the objects of test/e2e/setup/23ai/00_vectors.sql, run first by tools/e2e-setup.sh, and a 23ai+ server AND client)
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT * FROM e2e_vectors ORDER BY id');
DESCRIBE SELECT * FROM r;
SELECT * FROM r ORDER BY id;
CREATE TEMP TABLE checks AS
SELECT 'VECTOR(3, FLOAT32) is FLOAT[]' AS name, typeof(any_value(v32)) = 'FLOAT[]' AS ok FROM r
UNION ALL SELECT 'VECTOR(3, FLOAT64) is DOUBLE[]', typeof(any_value(v64)) = 'DOUBLE[]' FROM r
UNION ALL SELECT 'VECTOR(3, INT8) is FLOAT[]', typeof(any_value(v8)) = 'FLOAT[]' FROM r
UNION ALL SELECT 'VECTOR(*, *) is DOUBLE[]', typeof(any_value(vflex)) = 'DOUBLE[]' FROM r
UNION ALL SELECT 'VECTOR(*, FLOAT32) is FLOAT[]', typeof(any_value(vdim)) = 'FLOAT[]' FROM r
UNION ALL SELECT 'VECTOR(3, *) is DOUBLE[]', typeof(any_value(vfmt)) = 'DOUBLE[]' FROM r
UNION ALL SELECT 'four rows', count(*) = 4 FROM r
UNION ALL SELECT 'FLOAT32 values', v32 = [1.5, 2, 3]::FLOAT[] FROM r WHERE id = 1
UNION ALL SELECT 'FLOAT64 values', v64 = [1.5, 2, 3]::DOUBLE[] FROM r WHERE id = 1
UNION ALL SELECT 'INT8 values', v8 = [1, -2, 127]::FLOAT[] FROM r WHERE id = 1
UNION ALL SELECT 'INT8 limits -128 and 127', v8 = [-128, 0, 127]::FLOAT[] FROM r WHERE id = 3
UNION ALL SELECT 'flexible (*, *), 2 dimensions', vflex = [1, 2]::DOUBLE[] FROM r WHERE id = 1
UNION ALL SELECT 'flexible (*, *), 5 dimensions in the next row', vflex = [1, 2, 3, 4, 5]::DOUBLE[] FROM r WHERE id = 3
UNION ALL SELECT 'flexible dimensions, FLOAT32: 4 dimensions', vdim = [1.5, 2.5, 3.5, 4.5]::FLOAT[] FROM r WHERE id = 1
UNION ALL SELECT 'flexible dimensions, FLOAT32: 1 dimension', vdim = [9]::FLOAT[] FROM r WHERE id = 3
UNION ALL SELECT 'flexible format, 3 dimensions', vfmt = [7, 8, 9]::DOUBLE[] FROM r WHERE id = 1
UNION ALL SELECT 'FLOAT32 keeps float precision (0.1 as a float)', v32[1] = 0.1::FLOAT AND v32[3] = 0.3::FLOAT FROM r WHERE id = 4
UNION ALL SELECT 'FLOAT64 keeps double precision (0.1 as a double)', v64[1] = 0.1::DOUBLE AND v64[3] = 0.3::DOUBLE FROM r WHERE id = 4
UNION ALL SELECT 'flexible values are exact binary fractions', vflex = [0.5]::DOUBLE[] AND vfmt = [0.5, 0.25, 0.125]::DOUBLE[] AND vdim = [0.25, 0.75]::FLOAT[] FROM r WHERE id = 4;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
