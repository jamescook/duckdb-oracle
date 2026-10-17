-- e2e: unconstrained_number := 'varchar' is exact, 'lossy_double' is the old rounding behaviour
CREATE TEMP TABLE exact AS SELECT * FROM oracle_query('@DSN@',
  'SELECT 9007199254740993 * COUNT(*) AS big FROM dual', unconstrained_number := 'varchar');
CREATE TEMP TABLE lossy AS SELECT * FROM oracle_query('@DSN@',
  'SELECT 9007199254740993 * COUNT(*) AS big FROM dual', unconstrained_number := 'lossy_double');
SELECT * FROM exact;
SELECT * FROM lossy;
CREATE TEMP TABLE checks AS
SELECT 'varchar mode is VARCHAR' AS name, typeof(big) = 'VARCHAR' AS ok FROM exact
UNION ALL SELECT 'varchar mode is exact', big = '9007199254740993' FROM exact
UNION ALL SELECT 'lossy mode is DOUBLE', typeof(big) = 'DOUBLE' FROM lossy
UNION ALL SELECT 'lossy mode rounds to 2^53', big = 9007199254740992 FROM lossy;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
