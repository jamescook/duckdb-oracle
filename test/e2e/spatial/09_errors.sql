-- e2e: bad geometry options and unsupported object types are clear errors, and the process keeps running
-- expect-error: geometry must be 'wkb' or 'wkt'
-- expect-error: unsupported Oracle object type MDSYS.SDO_POINT_TYPE
-- expect-output: process-still-running
-- timeout: 120
.bail off
SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL) AS geom FROM dual', geometry := 'geojson');
-- an object type other than SDO_GEOMETRY stays unsupported, and the error names it
SELECT * FROM oracle_query('@DSN@', 'SELECT SDO_POINT_TYPE(1, 2, NULL) AS p FROM dual');
SELECT 'process-still-running' AS status;
