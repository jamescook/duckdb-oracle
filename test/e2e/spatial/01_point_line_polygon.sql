-- e2e: SDO_GEOMETRY columns (point, line, polygon, polygon with a hole) come back as WKB BLOBs that DuckDB reads
-- (ST_GeomFromWKB / ST_AsText are in DuckDB 1.5 core; older DuckDB needs INSTALL spatial; LOAD spatial;)
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT 1 AS id, ''point'' AS kind,
    SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1.5, -2, NULL), NULL, NULL) AS geom FROM dual
  UNION ALL SELECT 2, ''line'',
    SDO_GEOMETRY(2002, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 2, 1), SDO_ORDINATE_ARRAY(0, 0, 1, 1, 2, 0)) FROM dual
  UNION ALL SELECT 3, ''polygon'',
    SDO_GEOMETRY(2003, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 1003, 1), SDO_ORDINATE_ARRAY(0, 0, 4, 0, 4, 4, 0, 4, 0, 0)) FROM dual
  UNION ALL SELECT 4, ''polygon with hole'',
    SDO_GEOMETRY(2003, 4326, NULL, SDO_ELEM_INFO_ARRAY(1, 1003, 1, 11, 2003, 1),
                 SDO_ORDINATE_ARRAY(0, 0, 10, 0, 10, 10, 0, 10, 0, 0, 2, 2, 2, 4, 4, 4, 4, 2, 2, 2)) FROM dual');
DESCRIBE SELECT * FROM r;
-- the text form, and its coordinate pairs without regard to the order Oracle chose for a ring
CREATE TEMP TABLE t AS SELECT id, ST_AsText(ST_GeomFromWKB(geom)) AS wkt,
       list_sort(regexp_extract_all(ST_AsText(ST_GeomFromWKB(geom)), '-?[0-9.]+ -?[0-9.]+')) AS pairs FROM r;
SELECT * FROM t ORDER BY id;
CREATE TEMP TABLE checks AS
SELECT 'four rows' AS name, count(*) = 4 AS ok FROM r
UNION ALL SELECT 'geom is BLOB', typeof(any_value(geom)) = 'BLOB' FROM r
UNION ALL SELECT 'the other columns are untouched', list(kind ORDER BY id) = ['point', 'line', 'polygon', 'polygon with hole'] FROM r
UNION ALL SELECT 'point', wkt = 'POINT (1.5 -2)' FROM t WHERE id = 1
UNION ALL SELECT 'line keeps its vertex order', wkt = 'LINESTRING (0 0, 1 1, 2 0)' FROM t WHERE id = 2
UNION ALL SELECT 'polygon is a POLYGON with its 5 ring points', starts_with(wkt, 'POLYGON') AND pairs = ['0 0', '0 0', '0 4', '4 0', '4 4'] FROM t WHERE id = 3
UNION ALL SELECT 'polygon with a hole has two rings and all 10 points',
       starts_with(wkt, 'POLYGON') AND len(regexp_extract_all(wkt, '\(')) = 3 AND len(pairs) = 10 AND list_contains(pairs, '2 4') AND list_contains(pairs, '10 10') FROM t WHERE id = 4;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
