-- e2e: Oracle server version (informational)
-- optional
-- (V$VERSION is not readable by every account; if it is not, this shows as a warning, not a failure.)
SELECT * FROM oracle_query('@DSN@', 'SELECT banner FROM v$version WHERE banner LIKE ''Oracle%''');
