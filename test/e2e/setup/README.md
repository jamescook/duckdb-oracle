# Setup scripts for the end-to-end tests

Most tests in `test/e2e` build their data from literals on `dual` and need nothing. A few need real objects: VECTOR columns
with a declared type (fixed and flexible dimensions) and the schema/synonym tests. Those objects are created by the scripts here,
run with SQL*Plus **as SYSTEM** by `tools/e2e-setup.sh` before the tests (the hosted `e2e-oracle` CI job does this on a throw-away
container). The tests then log in as the ordinary test user (`E2E_APP`).

* `common/` runs on every database, `23ai/` only on Oracle 23ai or newer.
* Scripts run in file-name order and stop at the first error (`WHENEVER SQLERROR EXIT FAILURE`), unless a script says otherwise.
* They drop and recreate their objects, so re-running is safe. They only touch `E2E_*` objects.
* **Never run these against a database you care about.** They create users and public synonyms.
* A test that needs a script says so in its header comment.
