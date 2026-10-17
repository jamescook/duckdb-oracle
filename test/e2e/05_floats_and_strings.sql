-- e2e: BINARY_DOUBLE/FLOAT and VARCHAR2 / NVARCHAR2 / CHAR / NCHAR (UTF-8 and padding)
-- (Non-ASCII text is built with UNISTR so this file stays ASCII. The VARCHAR2 case uses only e-acute,
--  which every Western database character set has; the euro sign goes through NVARCHAR2.)
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  CAST(1.5 AS BINARY_DOUBLE)                                     AS bin_double,
  CAST(2.5 AS BINARY_FLOAT)                                      AS bin_float,
  CAST(''hello'' AS VARCHAR2(20))                                AS vc,
  CAST(UNISTR(''h\00E9llo'') AS VARCHAR2(20))                    AS vc_utf8,
  CAST(UNISTR(''gr\00FC\00DFe \20AC'') AS NVARCHAR2(20))         AS nvc,
  CAST(''abc'' AS CHAR(5))                                       AS ch,
  CAST(UNISTR(''xyz'') AS NCHAR(5))                              AS nch,
  CAST('''' AS VARCHAR2(5))                                      AS empty_is_null
FROM dual');
DESCRIBE SELECT * FROM r;
SELECT * FROM r;
CREATE TEMP TABLE checks AS
SELECT 'bin_double is DOUBLE' AS name, typeof(bin_double) = 'DOUBLE' AS ok FROM r
UNION ALL SELECT 'bin_double = 1.5', bin_double = 1.5 FROM r
UNION ALL SELECT 'bin_float is FLOAT', typeof(bin_float) = 'FLOAT' FROM r
UNION ALL SELECT 'bin_float = 2.5', bin_float = 2.5 FROM r
UNION ALL SELECT 'vc is VARCHAR', typeof(vc) = 'VARCHAR' FROM r
UNION ALL SELECT 'vc = hello', vc = 'hello' FROM r
UNION ALL SELECT 'vc_utf8 keeps e-acute', vc_utf8 = 'h' || chr(233) || 'llo' FROM r
UNION ALL SELECT 'nvc keeps u-umlaut, sharp s, euro', nvc = 'gr' || chr(252) || chr(223) || 'e ' || chr(8364) FROM r
UNION ALL SELECT 'nvc is VARCHAR', typeof(nvc) = 'VARCHAR' FROM r
UNION ALL SELECT 'CHAR(5) keeps blank padding', ch = 'abc  ' FROM r
UNION ALL SELECT 'NCHAR(5) keeps blank padding', nch = 'xyz  ' FROM r
UNION ALL SELECT 'Oracle empty string is NULL', empty_is_null IS NULL FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
