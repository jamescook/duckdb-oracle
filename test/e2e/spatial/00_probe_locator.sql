-- e2e: Oracle Locator/Spatial is present: SDO_GEOMETRY and SDO_UTIL.TO_WKBGEOMETRY / TO_WKTGEOMETRY work
-- (Locator ships with Oracle XE, Free and every Database edition. If this test fails, the other spatial tests
--  fail for the same reason: the database lacks Locator or the account may not use MDSYS.SDO_UTIL.)
-- timeout: 120
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  MDSYS.SDO_UTIL.TO_WKTGEOMETRY(SDO_GEOMETRY(2001, NULL, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL)) AS wkt,
  MDSYS.SDO_UTIL.TO_WKBGEOMETRY(SDO_GEOMETRY(2001, NULL, SDO_POINT_TYPE(1, 2, NULL), NULL, NULL)) AS wkb
FROM dual');
CREATE TEMP TABLE checks AS
SELECT 'one row' AS name, count(*) = 1 AS ok FROM r
UNION ALL SELECT 'TO_WKTGEOMETRY returns a POINT', upper(wkt) LIKE 'POINT%' FROM r
UNION ALL SELECT 'TO_WKBGEOMETRY returns a BLOB with the 21 bytes of a 2D point', typeof(wkb) = 'BLOB' AND octet_length(wkb) = 21 FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
