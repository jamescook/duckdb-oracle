-- e2e: 3000 geometry rows (two DuckDB vectors), each geometry belongs to its row; LIMIT stops early and cleanly
-- timeout: 180
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT LEVEL AS n,
  SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(LEVEL, -LEVEL, NULL), NULL, NULL) AS geom FROM dual CONNECT BY LEVEL <= 3000');
CREATE TEMP TABLE pts AS SELECT n,
  regexp_extract(ST_AsText(ST_GeomFromWKB(geom)), 'POINT \((-?[0-9.]+) ', 1)::DOUBLE AS x,
  regexp_extract(ST_AsText(ST_GeomFromWKB(geom)), ' (-?[0-9.]+)\)', 1)::DOUBLE AS y FROM r;
CREATE TEMP TABLE few AS SELECT * FROM oracle_query('@DSN@', 'SELECT LEVEL AS n,
  SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(LEVEL, LEVEL, NULL), NULL, NULL) AS geom FROM dual CONNECT BY LEVEL <= 1000000') LIMIT 5;
CREATE TEMP TABLE checks AS
SELECT '3000 rows' AS name, count(*) = 3000 AS ok FROM pts
UNION ALL SELECT 'x is the row number', count(*) FILTER (WHERE x = n) = 3000 FROM pts
UNION ALL SELECT 'y is minus the row number', count(*) FILTER (WHERE y = -n) = 3000 FROM pts
UNION ALL SELECT 'the sum of x is 4501500', sum(x) = 4501500 FROM pts
UNION ALL SELECT 'LIMIT 5 of a million geometries returned 5 rows', count(*) = 5 FROM few;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
