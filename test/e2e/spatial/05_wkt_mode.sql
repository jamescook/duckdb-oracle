-- e2e: geometry := 'wkt' returns VARCHAR text from SDO_UTIL.TO_WKTGEOMETRY; NULL stays NULL
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT 1 AS id, SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS geom FROM dual
  UNION ALL SELECT 2, SDO_GEOMETRY(2002, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 2, 1), SDO_ORDINATE_ARRAY(0, 0, 5, 5)) FROM dual
  UNION ALL SELECT 3, CAST(NULL AS MDSYS.SDO_GEOMETRY) FROM dual', geometry := 'wkt');
CREATE TEMP TABLE w AS SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS geom FROM dual', geometry := 'WKB');
SELECT * FROM r ORDER BY id;
CREATE TEMP TABLE checks AS
SELECT 'geom is VARCHAR' AS name, typeof(any_value(geom)) = 'VARCHAR' AS ok FROM r
UNION ALL SELECT 'point text', upper(geom) LIKE 'POINT%' AND regexp_matches(geom, '1\D+2') FROM r WHERE id = 1
UNION ALL SELECT 'line text', upper(geom) LIKE 'LINESTRING%' AND regexp_matches(geom, '0\D+0\D+5\D+5') FROM r WHERE id = 2
UNION ALL SELECT 'NULL stays NULL', geom IS NULL FROM r WHERE id = 3
UNION ALL SELECT 'the WKB of the same geometry round-trips', ST_AsText(ST_GeomFromWKB((SELECT any_value(geom) FROM w))) = 'POINT (1 2)'
UNION ALL SELECT 'geometry := WKB (any case) gives the BLOB form', typeof(any_value(geom)) = 'BLOB' FROM w;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
