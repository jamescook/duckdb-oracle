# Writing to Oracle from DuckDB: assessment

**Question.** Can duckdb-oracle write rows to Oracle (array-bind inserts in one transaction) using only DuckDB's *stable* C
extension API, without breaking what it already does?

**Answer: not cleanly, not at the version floor this extension supports.** There is one good design, a `COPY ... TO` function, but
its API is stable only from DuckDB **1.5.6**, and using it would raise the minimum DuckDB version of the whole extension from
1.2.0 to 1.5.6 or split the project into two builds. No writes were implemented. This note records what was checked, so the decision
can be revisited when the floor moves.

The facts below come from the vendored headers (`third_party/duckdb/v1.5.6/duckdb.h`, the `history:` line of each function) and
from the build files. Nothing here was run against Oracle: no Oracle server was reachable from the environment this was written in.

## What the stable C API offers

| Mechanism | Stable since | Can it write out? |
|---|---|---|
| **Copy functions** (`duckdb_create_copy_function`, `..._set_bind/_global_init/_sink/_finalize`, `duckdb_register_copy_function`, 33 functions) | unstable **1.5.0**, stable **1.5.6** | **Yes**: this is what `COPY (query) TO 'x' (FORMAT f)` is. Each function has a bind, a global init, a *sink* that receives DuckDB data chunks, and a *finalize* |
| Table functions | 0.3.3 | Only as a *source*. A table function has no table input, so there are no in/out table functions in the C API |
| Scalar functions | 1.1.0 | A scalar function sees chunks of its arguments, so it could run side effects, but it has **no end-of-statement hook**: nowhere to commit or roll back |
| Aggregate functions | 1.1.0 | `update` sees chunks, `combine` merges thread states, `finalize` returns a value. Argument types are fixed when the function is registered, so it cannot take "all columns of a query", and per-thread states are separate transactions unless every row is buffered into one state |
| Run SQL from an extension: `duckdb_connect`, `duckdb_query`, `duckdb_fetch_chunk` | 0.1.0 / 0.1.0 / 1.0.0 | Reads a query's result, on a *new* connection (see option B) |
| Client context inside a table function (`duckdb_table_function_get_client_context`) | unstable 1.4.0, stable **1.5.6** | Would give the caller's connection; not stable below 1.5.6 |
| Replacement scans, `ATTACH`/catalog/storage extensions, `INSERT INTO` a foreign table | not in the C API | These are C++ extension interfaces. There is no way to make `INSERT INTO oracle.t SELECT ...` work from the C API |

What Oracle side would need (all present in the vendored ODPI-C 26.0.0, `third_party/odpi/include/dpi.h`): `dpiConn_prepareStmt`
for `INSERT INTO t (cols) VALUES (:1, :2, ...)`, `dpiConn_newVar` with `maxArraySize` for each column, `dpiVar_setFromBytes` and
`dpiVar_setNumElementsInArray`, `dpiStmt_bindByPos`, `dpiStmt_executeMany` (not with `DPI_MODE_EXEC_COMMIT_ON_SUCCESS`, so nothing
commits early), `DPI_MODE_EXEC_BATCH_ERRORS` / `dpiStmt_getBatchErrors` for per-row error text, `dpiConn_commit` and
`dpiConn_rollback`.

## The options

**A. `COPY (SELECT ...) TO 'schema.table' (FORMAT oracle, DSN '...', ...)` using the copy-function API.** The natural fit:

* *global init* opens one session (credentials from the environment, exactly as `oracle_query`) and checks the target table;
* *sink* (may be called from several threads: serialise on a mutex around the one session) turns each chunk into array binds and
  calls `dpiStmt_executeMany` for batches of the chunk size;
* *finalize* calls `dpiConn_commit`; any error in *sink* or *finalize* is reported with `..._set_error`, which makes DuckDB abandon
  the statement, and the global state's destroy callback does `dpiConn_rollback` and closes the session. One transaction, commit
  on success, roll back on any error;
* the file path is the table name; the options struct carries the DSN, batch size and similar.

It is also the only mechanism that cannot be run twice by accident (see B). **The cost is the version floor.** The declarations are
behind `#if DUCKDB_API_VERSION_AT_LEAST(1, 5, 6)` in `duckdb.h` and the fields of the API struct are behind the same guard, and
`build.zig` translates the headers with the *target* version, so at the default target (1.2.0) a reference to any copy-function API
is a compile error. That is intentional: it is how the build proves that the shipped binary needs nothing above 1.2.0 (see
[BUILDING.md](../BUILDING.md)). Using the copy API means one of:

1. raise the footer/target version to 1.5.6: the extension would no longer load on DuckDB 1.2 to 1.5.5, which breaks existing users;
2. build a second flavor (a `duckdb_oracle` for DuckDB 1.5.6+ with writes, a second set of five zips and CI legs), or compile one
   module against 1.5.6 headers and register it only when `duckdb_library_version()` is at least 1.5.6. The second variant works at
   run time but removes the compile-time proof for that module and leaves two incompatible definitions of the API struct in one binary.

Neither is a small change to make quietly.

**B. `oracle_insert(dsn, table, 'SELECT ...')` as a table function that runs the SELECT on a second connection.** Possible on the
old stable API (`duckdb_connect`, `duckdb_query`, `duckdb_fetch_chunk`) once the database handle saved at load time is used. Rejected:

* the inner query runs in a *different* connection and transaction: it cannot see `TEMP` tables, the caller's uncommitted changes or
  CTEs, and the query is passed as text;
* a table function is not marked as having side effects. DuckDB may evaluate it more than once (for example a CTE referenced twice
  is inlined and runs twice), which would insert the rows twice. A `COPY` statement cannot be duplicated like that.

**C. An aggregate (`SELECT oracle_insert_agg(...) FROM ...`).** Rejected: fixed argument list per registration, per-thread states are
separate Oracle transactions unless all rows are buffered into one state, and an aggregate is also free to be re-evaluated.

**D. A scalar function with side effects.** Rejected: no end-of-statement hook, so no way to commit once or to roll back on error.

**E. `ATTACH` / `INSERT INTO`.** Not available in the C API.

## Decision

Stop after this note, as agreed in advance for the case where the stable API has no clean path at the supported floor. Nothing
from the unstable API was used.

## What is needed to go ahead

1. **A decision about the DuckDB floor** (option A, 1 or 2). That is a product decision, not a coding one.
2. A write-side type mapping. DuckDB to Oracle bind types for the minimal set: `BIGINT`/`INTEGER` to `NUMBER`, `DECIMAL` via text
   to `NUMBER`, `DOUBLE`/`FLOAT` to `BINARY_DOUBLE`/`BINARY_FLOAT`, `VARCHAR` to `VARCHAR2` (and `CLOB` above 4000 bytes),
   `TIMESTAMP` to `TIMESTAMP`, `TIMESTAMPTZ` to `TIMESTAMP WITH TIME ZONE`, `BLOB` to `RAW`/`BLOB`, `BOOLEAN` only on 23ai; anything
   else refused at bind. Oracle converts a bind to the column's type, but the edges (NUMBER overflow, DATE vs TIMESTAMP, empty
   string to NULL in Oracle) need explicit tests.
3. A policy for the target table: it must exist (no `CREATE TABLE`), the column list comes from the COPY's columns, and what happens
   on a type mismatch.
4. End-to-end tests against real databases, in the same hosted jobs as the read tests: batching across several array sizes,
   NULLs, a type round-trip per mapped type (write with `COPY`, read back with `oracle_query`), **rollback on error** (a failing
   row in the second batch must leave the table untouched), an error in finalize, and a concurrent-sink case. These need tables and
   `INSERT` rights, which `test/e2e/setup/` can provide.
5. Documentation of the write semantics: one transaction per COPY, no partial commits, and what the DuckDB error looks like.

The risks that justify waiting rather than guessing: a write path can lose or duplicate data, it has never been exercised against a
live Oracle server by anyone here, and the transaction guarantees depend on DuckDB's behaviour when a sink fails, which the headers
describe but which has to be observed on a real build before anything is promised.
