-- e2e: geometry_srid := true adds a BIGINT <name>_srid column after each geometry column.
-- WKB itself carries no SRID, so without the option the SRID is dropped.
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT 1 AS id, SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS geom FROM dual
  UNION ALL SELECT 2, SDO_GEOMETRY(2001, 3857, SDO_POINT_TYPE(3, 4, NULL), NULL, NULL) FROM dual
  UNION ALL SELECT 3, SDO_GEOMETRY(2001, NULL, SDO_POINT_TYPE(5, 6, NULL), NULL, NULL) FROM dual
  UNION ALL SELECT 4, CAST(NULL AS MDSYS.SDO_GEOMETRY) FROM dual', geometry_srid := true);
CREATE TEMP TABLE plain AS SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS geom FROM dual');
CREATE TEMP TABLE twice AS SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS a,
  7 AS between_them, SDO_GEOMETRY(2001, 3857, SDO_POINT_TYPE(3, 4, NULL), NULL, NULL) AS b FROM dual', geometry_srid := true);
DESCRIBE SELECT * FROM r;
SELECT * EXCLUDE (geom) FROM r ORDER BY id;
CREATE TEMP TABLE checks AS
SELECT 'columns are id, geom, geom_srid' AS name,
       (SELECT list(column_name ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name = 'r') = ['id', 'geom', 'geom_srid'] AS ok
UNION ALL SELECT 'geom_srid is a BIGINT', (SELECT data_type FROM information_schema.columns WHERE table_name = 'r' AND column_name = 'geom_srid') = 'BIGINT'
UNION ALL SELECT 'SRID 4326', geom_srid = 4326 FROM r WHERE id = 1
UNION ALL SELECT 'SRID 3857', geom_srid = 3857 FROM r WHERE id = 2
UNION ALL SELECT 'a geometry without an SRID has a NULL SRID', geom_srid IS NULL AND geom IS NOT NULL FROM r WHERE id = 3
UNION ALL SELECT 'a NULL geometry has a NULL SRID', geom_srid IS NULL AND geom IS NULL FROM r WHERE id = 4
UNION ALL SELECT 'without the option there is only the geometry column', (SELECT count(*) FROM information_schema.columns WHERE table_name = 'plain') = 1
UNION ALL SELECT 'two geometries: a, a_srid, between_them, b, b_srid',
       (SELECT list(column_name ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name = 'twice') = ['a', 'a_srid', 'between_them', 'b', 'b_srid']
UNION ALL SELECT 'two geometries: each SRID belongs to its own geometry', a_srid = 4326 AND b_srid = 3857 AND between_them = 7 FROM twice;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
