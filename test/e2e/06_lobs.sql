-- e2e: CLOB / NCLOB, a CLOB beyond 64 KiB, and many LOB rows (crossing the LOB batch size)
-- timeout: 240
CREATE TEMP TABLE small AS SELECT * FROM oracle_query('@DSN@',
  'SELECT TO_CLOB(''clob text'') AS c, TO_NCLOB(''nclob text'') AS nc, CAST(NULL AS CLOB) AS c_null FROM dual');
CREATE TEMP TABLE big AS SELECT * FROM oracle_query('@DSN@',
  'SELECT TO_CLOB(RPAD(''a'', 4000, ''a'')) || TO_CLOB(RPAD(''b'', 4000, ''b'')) || TO_CLOB(RPAD(''c'', 4000, ''c'')) || TO_CLOB(RPAD(''d'', 4000, ''d'')) || TO_CLOB(RPAD(''e'', 4000, ''e'')) || TO_CLOB(RPAD(''f'', 4000, ''f'')) || TO_CLOB(RPAD(''g'', 4000, ''g'')) || TO_CLOB(RPAD(''h'', 4000, ''h'')) || TO_CLOB(RPAD(''i'', 4000, ''i'')) || TO_CLOB(RPAD(''j'', 4000, ''j'')) || TO_CLOB(RPAD(''k'', 4000, ''k'')) || TO_CLOB(RPAD(''l'', 4000, ''l'')) || TO_CLOB(RPAD(''m'', 4000, ''m'')) || TO_CLOB(RPAD(''n'', 4000, ''n'')) || TO_CLOB(RPAD(''o'', 4000, ''o'')) || TO_CLOB(RPAD(''p'', 4000, ''p'')) || TO_CLOB(RPAD(''q'', 4000, ''q'')) || TO_CLOB(RPAD(''r'', 4000, ''r'')) || TO_CLOB(RPAD(''s'', 4000, ''s'')) || TO_CLOB(RPAD(''t'', 4000, ''t'')) AS c FROM dual');
CREATE TEMP TABLE many AS SELECT * FROM oracle_query('@DSN@',
  'SELECT CAST(LEVEL AS NUMBER(10)) AS id, TO_CLOB(RPAD(''a'', 4000, ''a'')) || TO_CLOB(RPAD(''b'', 4000, ''b'')) || TO_CLOB(RPAD(''c'', 4000, ''c'')) || TO_CLOB(RPAD(''d'', 4000, ''d'')) || TO_CLOB(RPAD(''e'', 4000, ''e'')) AS c FROM dual CONNECT BY LEVEL <= 70');
SELECT * FROM small;
CREATE TEMP TABLE checks AS
SELECT 'CLOB is VARCHAR' AS name, typeof(c) = 'VARCHAR' AS ok FROM small
UNION ALL SELECT 'CLOB value', c = 'clob text' FROM small
UNION ALL SELECT 'NCLOB value', nc = 'nclob text' FROM small
UNION ALL SELECT 'NULL CLOB', c_null IS NULL FROM small
UNION ALL SELECT '80000-character CLOB length', length(c) = 80000 FROM big
UNION ALL SELECT '80000-character CLOB first 4000', left(c, 4000) = repeat('a', 4000) FROM big
UNION ALL SELECT '80000-character CLOB last 4000', right(c, 4000) = repeat('t', 4000) FROM big
UNION ALL SELECT '80000-character CLOB middle', substr(c, 40001, 4000) = repeat('k', 4000) FROM big
UNION ALL SELECT '70 LOB rows', count(*) = 70 FROM many
UNION ALL SELECT '70 distinct ids', count(DISTINCT id) = 70 FROM many
UNION ALL SELECT 'every LOB has 20000 characters', count(*) FILTER (WHERE length(c) = 20000) = 70 FROM many
UNION ALL SELECT 'LOB rows keep their content', count(*) FILTER (WHERE left(c, 4000) = repeat('a', 4000) AND right(c, 4000) = repeat('e', 4000)) = 70 FROM many;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
