-- e2e: NULL geometries stay NULL, between non-NULL ones and when every row is NULL
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT 1 AS id, SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS geom FROM dual
  UNION ALL SELECT 2, CAST(NULL AS MDSYS.SDO_GEOMETRY) FROM dual
  UNION ALL SELECT 3, SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(3, 4, NULL), NULL, NULL) FROM dual');
CREATE TEMP TABLE only_null AS SELECT * FROM oracle_query('@DSN@', 'SELECT CAST(NULL AS MDSYS.SDO_GEOMETRY) AS geom FROM dual');
CREATE TEMP TABLE checks AS
SELECT 'three rows' AS name, count(*) = 3 AS ok FROM r
UNION ALL SELECT 'the NULL row is NULL', geom IS NULL FROM r WHERE id = 2
UNION ALL SELECT 'the other rows are not NULL', count(*) FILTER (WHERE geom IS NOT NULL) = 2 FROM r
UNION ALL SELECT 'a point after the NULL row', ST_AsText(ST_GeomFromWKB(geom)) = 'POINT (3 4)' FROM r WHERE id = 3
UNION ALL SELECT 'an all-NULL geometry column is a NULL BLOB', count(*) = 1 AND count(geom) = 0 AND typeof(any_value(geom)) = 'BLOB' FROM only_null;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
