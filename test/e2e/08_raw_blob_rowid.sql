-- e2e: RAW, BLOB and ROWID
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  HEXTORAW(''00FF10'')                  AS raw_col,
  UTL_RAW.CAST_TO_RAW(''abc'')          AS raw_text,
  TO_BLOB(HEXTORAW(''DEADBEEF''))       AS blob_col,
  ROWID                                 AS rid
FROM dual');
DESCRIBE SELECT * FROM r;
CREATE TEMP TABLE checks AS
SELECT 'RAW is BLOB' AS name, typeof(raw_col) = 'BLOB' AS ok FROM r
UNION ALL SELECT 'RAW bytes', raw_col = '\x00\xFF\x10'::BLOB FROM r
UNION ALL SELECT 'RAW from text', raw_text = 'abc'::BLOB FROM r
UNION ALL SELECT 'BLOB is BLOB', typeof(blob_col) = 'BLOB' FROM r
UNION ALL SELECT 'BLOB bytes', blob_col = '\xDE\xAD\xBE\xEF'::BLOB FROM r
UNION ALL SELECT 'ROWID is VARCHAR', typeof(rid) = 'VARCHAR' FROM r
UNION ALL SELECT 'ROWID looks like a rowid', length(rid) >= 15 FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
