-- e2e: Oracle errors surface with their ORA- codes and the process keeps running
-- (The bad-credentials case uses a user name that does not exist. Never use a real account with a wrong
--  password here: repeated failures would lock it.)
-- expect-error: ORA-00936
-- expect-error: ORA-00942
-- expect-error: ORA-01017
-- expect-error: only runs queries
-- expect-error: FOR UPDATE
-- expect-output: process-still-running
-- expect-output: oracle-still-usable: 1
.bail off
-- invalid SQL
SELECT * FROM oracle_query('@DSN@', 'SELECT FROM WHERE');
-- unknown table
SELECT * FROM oracle_query('@DSN@', 'SELECT * FROM e2e_no_such_table_xyz');
-- bad credentials
SELECT * FROM oracle_query('@DSN@', 'SELECT 1 FROM dual', user := 'E2E_NO_SUCH_USER');
-- statements that are not queries are refused before anything runs
SELECT * FROM oracle_query('@DSN@', 'CREATE TABLE e2e_must_not_exist (a NUMBER)');
SELECT * FROM oracle_query('@DSN@', 'SELECT * FROM dual FOR UPDATE');
-- after all of that the process is alive and Oracle is still usable
SELECT 'process-still-running' AS status;
SELECT 'oracle-still-usable: ' || count(*) AS status FROM oracle_query('@DSN@', 'SELECT 1 AS one FROM dual');
