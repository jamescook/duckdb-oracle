-- e2e: 3D geometries (probe). What Oracle's SDO_UTIL.TO_WKBGEOMETRY does with a Z coordinate is Oracle's behaviour,
-- not duckdb-oracle's; this test records it. It passes if the Z survives; it is optional so a different outcome is a warning.
-- optional
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_GEOMETRY(3001, NULL, SDO_POINT_TYPE(1, 2, 3), NULL, NULL) AS geom FROM dual');
SELECT ST_AsText(ST_GeomFromWKB(geom)) AS wkt FROM r;
CREATE TEMP TABLE checks AS
SELECT '3D point keeps its Z' AS name, upper(ST_AsText(ST_GeomFromWKB(geom))) IN ('POINT Z (1 2 3)', 'POINT Z(1 2 3)') AS ok FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
