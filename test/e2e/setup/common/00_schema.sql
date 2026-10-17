-- Objects for the oracle_scan / oracle_tables / current_schema tests (run as SYSTEM). Works on 19c and newer.
-- Needs the test login E2E_APP to exist (the hosted CI creates it with the container image's APP_USER setting).
-- E2E_OWNER is a second schema with no login. Everything here is named E2E_* / e2e_*.
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON FEEDBACK ON

BEGIN
  FOR u IN (SELECT username FROM dba_users WHERE username = 'E2E_OWNER') LOOP
    EXECUTE IMMEDIATE 'DROP USER ' || u.username || ' CASCADE';
  END LOOP;
END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PUBLIC SYNONYM e2e_pub_people'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1432 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP PUBLIC SYNONYM e2e_shadowed'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1432 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP SYNONYM e2e_app.people_syn'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -1434 THEN RAISE; END IF; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE e2e_app.e2e_shadowed PURGE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;
/

GRANT UNLIMITED TABLESPACE TO e2e_app;
CREATE USER e2e_owner NO AUTHENTICATION;
GRANT UNLIMITED TABLESPACE TO e2e_owner;

-- the second schema: a table, a view over it, and a table whose name and column name are case-sensitive and have a space
CREATE TABLE e2e_owner.people (id NUMBER(10), name VARCHAR2(50));
INSERT INTO e2e_owner.people VALUES (1, 'Ada');
INSERT INTO e2e_owner.people VALUES (2, 'Grace');
INSERT INTO e2e_owner.people VALUES (3, NULL);
CREATE VIEW e2e_owner.people_v AS SELECT id, UPPER(name) AS name_upper FROM e2e_owner.people;
CREATE TABLE e2e_owner."MixedCase" (id NUMBER(10), "Odd Col" VARCHAR2(20));
INSERT INTO e2e_owner."MixedCase" VALUES (10, 'ten');
INSERT INTO e2e_owner."MixedCase" VALUES (20, 'twenty');
COMMIT;
GRANT SELECT ON e2e_owner.people TO e2e_app;
GRANT SELECT ON e2e_owner.people_v TO e2e_app;
GRANT SELECT ON e2e_owner."MixedCase" TO e2e_app;

-- a private synonym in the test user's schema, and public synonyms
CREATE SYNONYM e2e_app.people_syn FOR e2e_owner.people;
CREATE PUBLIC SYNONYM e2e_pub_people FOR e2e_owner.people;

-- a name that is both a table in the test user's schema and a public synonym: the schema's own object must win
CREATE TABLE e2e_app.e2e_shadowed (id NUMBER(10), name VARCHAR2(50));
INSERT INTO e2e_app.e2e_shadowed VALUES (99, 'local table');
COMMIT;
CREATE PUBLIC SYNONYM e2e_shadowed FOR e2e_owner.people;
