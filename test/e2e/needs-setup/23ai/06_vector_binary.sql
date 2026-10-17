-- e2e: BINARY vectors: VECTOR(16, BINARY) arrives as UTINYINT[], the packed bytes (n/8 elements)
-- (needs test/e2e/setup/23ai/01_vectors_binary.sql. Optional: the literal syntax used to fill the table is the least certain
-- part of the setup, so if the table is missing this is a warning, not a failure.)
-- optional
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT id, b FROM e2e_vectors_binary ORDER BY id');
DESCRIBE SELECT * FROM r;
SELECT * FROM r ORDER BY id;
CREATE TEMP TABLE checks AS
SELECT 'two rows' AS name, count(*) = 2 AS ok FROM r
UNION ALL SELECT 'VECTOR(16, BINARY) is UTINYINT[]', typeof(any_value(b)) = 'UTINYINT[]' FROM r
UNION ALL SELECT '16 bits are 2 bytes: [1, 255]', b = [1, 255]::UTINYINT[] FROM r WHERE id = 1
UNION ALL SELECT 'NULL', b IS NULL FROM r WHERE id = 2;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
