-- e2e: case-sensitive and spaced column names, and duplicate column names, around a geometry column
-- (unique names: the query is wrapped as an inline view; duplicates: renamed positionally with a WITH column list)
-- timeout: 120
CREATE TEMP TABLE r1 AS SELECT * FROM oracle_query('@DSN@', 'SELECT 1 AS "Id", ''x'' AS "mixed Case",
  SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS "Geom Shape" FROM dual');
CREATE TEMP TABLE r2 AS SELECT * FROM oracle_query('@DSN@', 'SELECT 1 AS id, 2 AS id,
  SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(3, 4, NULL), NULL, NULL) AS geom FROM dual');
CREATE TEMP TABLE r3 AS SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(5, 6, NULL), NULL, NULL) AS geom FROM dual -- a trailing comment
');
CREATE TEMP TABLE r4 AS SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(7, 8, NULL), NULL, NULL) AS geom FROM dual;');
DESCRIBE SELECT * FROM r1;
DESCRIBE SELECT * FROM r2;
CREATE TEMP TABLE checks AS
SELECT 'case-sensitive and spaced names are kept' AS name,
       (SELECT list(column_name ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name = 'r1') = ['Id', 'mixed Case', 'Geom Shape'] AS ok
UNION ALL SELECT 'their values', "Id" = 1 AND "mixed Case" = 'x' AND ST_AsText(ST_GeomFromWKB("Geom Shape")) = 'POINT (1 2)' FROM r1
UNION ALL SELECT 'duplicate names: three columns, geometry is a BLOB', (SELECT count(*) FROM information_schema.columns WHERE table_name = 'r2') = 3
       AND (SELECT data_type FROM information_schema.columns WHERE table_name = 'r2' AND column_name = 'geom') = 'BLOB'
UNION ALL SELECT 'duplicate names: values by position', id = 1 AND id_1 = 2 AND ST_AsText(ST_GeomFromWKB(geom)) = 'POINT (3 4)' FROM r2
UNION ALL SELECT 'a trailing line comment in the query', ST_AsText(ST_GeomFromWKB(geom)) = 'POINT (5 6)' FROM r3
UNION ALL SELECT 'a trailing semicolon in the query', ST_AsText(ST_GeomFromWKB(geom)) = 'POINT (7 8)' FROM r4;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
