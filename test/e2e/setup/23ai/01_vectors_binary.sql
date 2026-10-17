-- BINARY vectors (probe): the literal syntax for packed bit vectors is the part of this that is least certain,
-- so a failure here must not stop the other setup. test/e2e/needs-setup/23ai/06_vector_binary.sql is optional for the same reason.
WHENEVER SQLERROR CONTINUE
SET ECHO ON FEEDBACK ON

BEGIN EXECUTE IMMEDIATE 'DROP TABLE e2e_app.e2e_vectors_binary PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE TABLE e2e_app.e2e_vectors_binary (id NUMBER(10) PRIMARY KEY, b VECTOR(16, BINARY));
INSERT INTO e2e_app.e2e_vectors_binary VALUES (1, TO_VECTOR('[1, 255]', 16, BINARY));
INSERT INTO e2e_app.e2e_vectors_binary VALUES (2, NULL);
COMMIT;
EXIT SUCCESS
