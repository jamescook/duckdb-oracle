-- e2e: oracle_scan and current_schema errors say what was tried; the process keeps running
-- (needs test/e2e/setup/common/00_schema.sql)
-- expect-error: nothing named 'e2e_no_such_thing' is visible to this user
-- expect-error: Tried: \(1\) "[A-Z0-9_$#]+"\."E2E_NO_SUCH_THING" - a table, view, materialized view or private synonym in the current schema; \(2\) a public synonym "E2E_NO_SUCH_THING"
-- expect-error: nothing named 'e2e_owner.mixedcase' is visible
-- expect-error: Tried: the table, view, materialized view or synonym "E2E_OWNER"\."MIXEDCASE"
-- expect-error: database links \(name@link\) are not supported
-- expect-error: at most two parts
-- expect-error: ORA-01435
-- expect-error: current_schema 'bad name' is not a valid schema name
-- expect-error: ORA-00942
-- expect-output: process-still-running
-- timeout: 120
.bail off
-- nothing of that name: bare name, both candidates are listed
SELECT * FROM oracle_scan('@DSN@', 'e2e_no_such_thing');
-- the real table is "MixedCase": the unquoted spelling is folded to MIXEDCASE, which does not exist
SELECT * FROM oracle_scan('@DSN@', 'e2e_owner.mixedcase');
SELECT * FROM oracle_scan('@DSN@', 'people@some_link');
SELECT * FROM oracle_scan('@DSN@', 'a.b.c');
-- a schema that does not exist
SELECT * FROM oracle_scan('@DSN@', 'people', current_schema := 'e2e_no_such_schema_x');
SELECT * FROM oracle_scan('@DSN@', 'people', current_schema := 'bad name');
-- without current_schema the test login has no PEOPLE (its synonym is PEOPLE_SYN)
SELECT * FROM oracle_query('@DSN@', 'SELECT * FROM people');
SELECT 'process-still-running' AS status;
