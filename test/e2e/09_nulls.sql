-- e2e: NULLs in every type family, and NULLs mixed with values across vector boundaries
-- timeout: 180
CREATE TEMP TABLE allnull AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  CAST(NULL AS NUMBER(10))                    AS n_int,
  CAST(NULL AS NUMBER(12,2))                  AS n_dec,
  CAST(NULL AS NUMBER)                        AS n_plain,
  CAST(NULL AS BINARY_DOUBLE)                 AS bd,
  CAST(NULL AS BINARY_FLOAT)                  AS bf,
  CAST(NULL AS VARCHAR2(10))                  AS vc,
  CAST(NULL AS NVARCHAR2(10))                 AS nvc,
  CAST(NULL AS CHAR(3))                       AS ch,
  CAST(NULL AS CLOB)                          AS clob_col,
  CAST(NULL AS DATE)                          AS d,
  CAST(NULL AS TIMESTAMP)                     AS ts,
  CAST(NULL AS TIMESTAMP WITH TIME ZONE)      AS tstz,
  CAST(NULL AS RAW(4))                        AS raw_col,
  CAST(NULL AS BLOB)                          AS blob_col,
  CAST(NULL AS INTERVAL DAY TO SECOND)        AS ids,
  CAST(NULL AS INTERVAL YEAR TO MONTH)        AS iym
FROM dual');
-- 6000 rows (three DuckDB vectors): every third row is NULL in every column
CREATE TEMP TABLE mixed AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  CASE WHEN MOD(LEVEL, 3) = 0 THEN NULL ELSE CAST(LEVEL AS NUMBER(10)) END                          AS n,
  CASE WHEN MOD(LEVEL, 3) = 0 THEN NULL ELSE ''v'' || LEVEL END                                       AS s,
  CASE WHEN MOD(LEVEL, 3) = 0 THEN NULL ELSE TO_DATE(''2020-01-01'', ''YYYY-MM-DD'') + LEVEL END    AS d,
  CASE WHEN MOD(LEVEL, 3) = 0 THEN NULL ELSE TO_CLOB(''c'' || LEVEL) END                              AS c
FROM dual CONNECT BY LEVEL <= 6000');
CREATE TEMP TABLE checks AS
SELECT 'one row of NULLs' AS name, count(*) = 1 AS ok FROM allnull
UNION ALL SELECT 'NUMBER(10) NULL', n_int IS NULL FROM allnull
UNION ALL SELECT 'NUMBER(12,2) NULL', n_dec IS NULL FROM allnull
UNION ALL SELECT 'NUMBER NULL', n_plain IS NULL FROM allnull
UNION ALL SELECT 'BINARY_DOUBLE NULL', bd IS NULL FROM allnull
UNION ALL SELECT 'BINARY_FLOAT NULL', bf IS NULL FROM allnull
UNION ALL SELECT 'VARCHAR2 NULL', vc IS NULL FROM allnull
UNION ALL SELECT 'NVARCHAR2 NULL', nvc IS NULL FROM allnull
UNION ALL SELECT 'CHAR NULL', ch IS NULL FROM allnull
UNION ALL SELECT 'CLOB NULL', clob_col IS NULL FROM allnull
UNION ALL SELECT 'DATE NULL', d IS NULL FROM allnull
UNION ALL SELECT 'TIMESTAMP NULL', ts IS NULL FROM allnull
UNION ALL SELECT 'TIMESTAMP WITH TIME ZONE NULL', tstz IS NULL FROM allnull
UNION ALL SELECT 'RAW NULL', raw_col IS NULL FROM allnull
UNION ALL SELECT 'BLOB NULL', blob_col IS NULL FROM allnull
UNION ALL SELECT 'INTERVAL DS NULL', ids IS NULL FROM allnull
UNION ALL SELECT 'INTERVAL YM NULL', iym IS NULL FROM allnull
UNION ALL SELECT 'mixed: 6000 rows', count(*) = 6000 FROM mixed
UNION ALL SELECT 'mixed: 2000 NULL numbers', count(*) FILTER (WHERE n IS NULL) = 2000 FROM mixed
UNION ALL SELECT 'mixed: 2000 NULL strings', count(*) FILTER (WHERE s IS NULL) = 2000 FROM mixed
UNION ALL SELECT 'mixed: 2000 NULL dates', count(*) FILTER (WHERE d IS NULL) = 2000 FROM mixed
UNION ALL SELECT 'mixed: 2000 NULL CLOBs', count(*) FILTER (WHERE c IS NULL) = 2000 FROM mixed
UNION ALL SELECT 'mixed: non-NULL numbers are intact', sum(n) = 12000000 FROM mixed
UNION ALL SELECT 'mixed: non-NULL strings are intact', count(*) FILTER (WHERE s IS NOT NULL AND s = 'v' || n) = 4000 FROM mixed
UNION ALL SELECT 'mixed: NULLs line up across columns', count(*) FILTER (WHERE (n IS NULL) = (s IS NULL) AND (s IS NULL) = (d IS NULL) AND (d IS NULL) = (c IS NULL)) = 6000 FROM mixed;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
