-- e2e: NUMBER variants map to BIGINT / DECIMAL / DOUBLE with exact values
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  CAST(42 AS NUMBER(10))                                         AS n_int,
  CAST(-987654321012345678 AS NUMBER(18))                        AS n_int18,
  CAST(12345 AS NUMBER(7,-2))                                    AS n_negscale,
  CAST(12345.67 AS NUMBER(12,2))                                 AS n_dec,
  CAST(0.000123 AS NUMBER(8,6))                                  AS n_small,
  CAST(123456789012345678901234 AS NUMBER(30))                   AS n_big30,
  CAST(12345678901234567890123456789012345678 AS NUMBER(38))     AS n_big38,
  CAST(1.5 AS NUMBER)                                            AS n_plain,
  CAST(2.25 AS FLOAT)                                            AS n_float
FROM dual');
DESCRIBE SELECT * FROM r;
SELECT * FROM r;
CREATE TEMP TABLE checks AS
SELECT 'n_int is BIGINT' AS name, typeof(n_int) = 'BIGINT' AS ok FROM r
UNION ALL SELECT 'n_int = 42', n_int = 42 FROM r
UNION ALL SELECT 'n_int18 is BIGINT', typeof(n_int18) = 'BIGINT' FROM r
UNION ALL SELECT 'n_int18 exact', n_int18 = -987654321012345678 FROM r
UNION ALL SELECT 'n_negscale is BIGINT', typeof(n_negscale) = 'BIGINT' FROM r
UNION ALL SELECT 'n_negscale = 12300', n_negscale = 12300 FROM r
UNION ALL SELECT 'n_dec is DECIMAL(12,2)', typeof(n_dec) = 'DECIMAL(12,2)' FROM r
UNION ALL SELECT 'n_dec = 12345.67', n_dec = 12345.67 FROM r
UNION ALL SELECT 'n_small is DECIMAL(8,6)', typeof(n_small) = 'DECIMAL(8,6)' FROM r
UNION ALL SELECT 'n_small = 0.000123', n_small = 0.000123 FROM r
UNION ALL SELECT 'n_big30 is DECIMAL(30,0)', typeof(n_big30) = 'DECIMAL(30,0)' FROM r
UNION ALL SELECT 'n_big30 exact', n_big30 = 123456789012345678901234 FROM r
UNION ALL SELECT 'n_big38 is DECIMAL(38,0)', typeof(n_big38) = 'DECIMAL(38,0)' FROM r
UNION ALL SELECT 'n_big38 exact', n_big38::VARCHAR = '12345678901234567890123456789012345678' FROM r
UNION ALL SELECT 'n_plain is DOUBLE', typeof(n_plain) = 'DOUBLE' FROM r
UNION ALL SELECT 'n_plain = 1.5', n_plain = 1.5 FROM r
UNION ALL SELECT 'n_float is DOUBLE', typeof(n_float) = 'DOUBLE' FROM r
UNION ALL SELECT 'n_float = 2.25', n_float = 2.25 FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
