-- e2e: multi-point, multi-line, multi-polygon and mixed collections
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT 1 AS id,
    SDO_GEOMETRY(2005, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 1, 2), SDO_ORDINATE_ARRAY(1, 2, 3, 4)) AS geom FROM dual
  UNION ALL SELECT 2,
    SDO_GEOMETRY(2006, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 2, 1, 5, 2, 1), SDO_ORDINATE_ARRAY(0, 0, 1, 1, 2, 2, 3, 3)) FROM dual
  UNION ALL SELECT 3,
    SDO_GEOMETRY(2007, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 1003, 1, 11, 1003, 1),
                 SDO_ORDINATE_ARRAY(0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 5, 5, 6, 5, 6, 6, 5, 6, 5, 5)) FROM dual
  UNION ALL SELECT 4,
    SDO_GEOMETRY(2004, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 1, 1, 3, 2, 1), SDO_ORDINATE_ARRAY(1, 2, 0, 0, 1, 1)) FROM dual');
CREATE TEMP TABLE t AS SELECT id, ST_AsText(ST_GeomFromWKB(geom)) AS wkt,
       list_sort(regexp_extract_all(ST_AsText(ST_GeomFromWKB(geom)), '-?[0-9.]+ -?[0-9.]+')) AS pairs FROM r;
SELECT * FROM t ORDER BY id;
CREATE TEMP TABLE checks AS
SELECT 'four rows' AS name, count(*) = 4 AS ok FROM r
UNION ALL SELECT 'multipoint', starts_with(wkt, 'MULTIPOINT') AND pairs = ['1 2', '3 4'] FROM t WHERE id = 1
UNION ALL SELECT 'multilinestring', starts_with(wkt, 'MULTILINESTRING') AND pairs = ['0 0', '1 1', '2 2', '3 3'] FROM t WHERE id = 2
UNION ALL SELECT 'multipolygon: two polygons, ten ring points',
       starts_with(wkt, 'MULTIPOLYGON') AND len(pairs) = 10 AND list_contains(pairs, '6 6') AND list_contains(pairs, '1 1') FROM t WHERE id = 3
UNION ALL SELECT 'collection of a point and a line',
       starts_with(wkt, 'GEOMETRYCOLLECTION') AND wkt LIKE '%POINT%' AND wkt LIKE '%LINESTRING%' AND pairs = ['0 0', '1 1', '1 2'] FROM t WHERE id = 4;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
