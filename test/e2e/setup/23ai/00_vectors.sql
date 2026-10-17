-- Tables with declared VECTOR column types, in the E2E_APP schema (run as SYSTEM). Oracle 23ai or newer.
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON FEEDBACK ON

BEGIN EXECUTE IMMEDIATE 'DROP TABLE e2e_app.e2e_vectors PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE e2e_app.e2e_vectors_many PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/

-- one column per kind of declaration: fixed dimensions + each fixed format, then the flexible forms
CREATE TABLE e2e_app.e2e_vectors (
  id     NUMBER(10) PRIMARY KEY,
  v32    VECTOR(3, FLOAT32),
  v64    VECTOR(3, FLOAT64),
  v8     VECTOR(3, INT8),
  vflex  VECTOR(*, *),
  vdim   VECTOR(*, FLOAT32),
  vfmt   VECTOR(3, *)
);

INSERT INTO e2e_app.e2e_vectors VALUES (1, '[1.5,2,3]',     '[1.5,2,3]',     '[1,-2,127]',  '[1,2]',       '[1.5,2.5,3.5,4.5]', '[7,8,9]');
INSERT INTO e2e_app.e2e_vectors VALUES (2, NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO e2e_app.e2e_vectors VALUES (3, '[-1,0,1]',      '[-1,0,1]',      '[-128,0,127]', '[1,2,3,4,5]', '[9]',               '[0,0,0]');
INSERT INTO e2e_app.e2e_vectors VALUES (4, '[0.1,0.2,0.3]', '[0.1,0.2,0.3]', '[5,6,7]',      '[0.5]',       '[0.25,0.75]',       '[0.5,0.25,0.125]');
COMMIT;

-- 2500 rows (two full DuckDB vectors and a bit): V has 4 dimensions and is NULL for every 7th row,
-- W is flexible and has 1, 2 or 3 dimensions depending on the row, so list offsets differ from row to row
CREATE TABLE e2e_app.e2e_vectors_many (
  id NUMBER(10) PRIMARY KEY,
  v  VECTOR(4, FLOAT32),
  w  VECTOR(*, *)
);

INSERT INTO e2e_app.e2e_vectors_many
SELECT LEVEL,
       CASE WHEN MOD(LEVEL, 7) = 0 THEN NULL
            ELSE TO_VECTOR('[' || LEVEL || ',' || (2 * LEVEL) || ',' || (3 * LEVEL) || ',' || MOD(LEVEL, 5) || ']', 4, FLOAT32) END,
       TO_VECTOR('[' || LEVEL || CASE MOD(LEVEL, 3) WHEN 1 THEN ',' || LEVEL WHEN 2 THEN ',' || LEVEL || ',' || LEVEL END || ']')
  FROM dual CONNECT BY LEVEL <= 2500;
COMMIT;

SELECT COUNT(*) AS rows_in_e2e_vectors_many FROM e2e_app.e2e_vectors_many;
