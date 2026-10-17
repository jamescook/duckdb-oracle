# Reference

Complete details for the two SQL functions, the environment variables the extension reads, the errors you may see, and the known
limitations. For a quick introduction see the [README](../README.md). Column types are in [TYPES.md](TYPES.md).

## `oracle_query`

```sql
oracle_query(dsn, sql [, user := ..., password_env := ..., auth := ..., unconstrained_number := ...,
                         geometry := ..., geometry_srid := ..., connect_timeout := ..., timeout := ...])
```

Table function. It runs one Oracle query and returns its result set.

| Argument | Meaning |
|---|---|
| `dsn VARCHAR` | Easy Connect string such as `localhost:1521/ORCLPDB1`, or a TNS alias (`TNS_ADMIN`) |
| `sql VARCHAR` | An Oracle `SELECT` / `WITH` query, using Oracle SQL dialect. One trailing `;` is removed (Oracle rejects it). `SELECT ... FOR UPDATE` is refused: it takes row locks that would stay held for the life of the session |
| `user := VARCHAR` | Optional. Defaults to `$ORACLE_USER` |
| `auth := VARCHAR` | Optional. `'password'` (default) or `'external'`: Oracle wallet (`/@alias`), Kerberos or OS authentication, where no user or password is given. `user` and `password_env` are refused in external mode |
| `password_env := VARCHAR` | Optional. Name of the environment variable that holds the password. Defaults to `ORACLE_PASSWORD` |
| `unconstrained_number := VARCHAR` | Optional. How a `NUMBER` with no exact `DECIMAL` form is returned (see [TYPES.md](TYPES.md#unconstrained-number)): `'double'` (default, checked), `'lossy_double'` or `'varchar'` |
| `geometry := VARCHAR` | Optional. What `MDSYS.SDO_GEOMETRY` columns become (see [TYPES.md](TYPES.md#spatial-data-sdo_geometry)): `'wkb'` (default, `BLOB`) or `'wkt'` (`VARCHAR`) |
| `geometry_srid := BOOLEAN` | Optional, default `false`. `true` adds a `BIGINT` `<name>_srid` column after every geometry column (NULL for a NULL geometry or a geometry without SRID) |
| `connect_timeout := BIGINT` | Optional. Seconds allowed for the connection handshake. Default **30**, `0` = no limit. Added to Easy Connect strings as `connect_timeout=N` unless the DSN already sets it; TNS aliases and `(DESCRIPTION=...)` strings are used unchanged (set it in `sqlnet.ora`/the descriptor) |
| `timeout := BIGINT` | Optional. Seconds allowed for each Oracle round trip on the session (describe, execute, every fetch). Default **600**, `0` = no limit. A query that legitimately takes longer than this before returning its first row needs a larger value |

**There is no `password` argument, on purpose.** DuckDB echoes the failing SQL text, literals included, in error
messages (for example a wrong password, ORA-01017) and the CLI keeps a history, so a password written in SQL leaks.
The password is read from the environment only. `password := '...'` from earlier versions is now rejected with
`Invalid named parameter "password"`; set `ORACLE_PASSWORD` (or the variable named by `password_env`) instead.

```sql
SELECT * FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT owner, table_name FROM all_tables');
SELECT * FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT * FROM dual', user := 'SAMPLE_DEV');
CREATE TABLE t AS SELECT * FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT * FROM sample.orders');
```

### How it works

* **Bind** checks the SQL (empty statements and `FOR UPDATE` are refused before any network traffic), connects (one Oracle session
  per `oracle_query` call), checks that the statement is a query (DDL, DML and PL/SQL are refused before anything executes),
  describes it without running it, and maps the columns.
* **Init** prepares and executes the statement and defines one fetch variable per column with array size = DuckDB's vector size (2048).
* **Scan**: each fetch fills one DuckDB chunk (array fetch). If one batch would need more than 64 MiB of fetch buffers (very wide
  rows, or LOB columns), duckdb-oracle fetches fewer rows per chunk.
* All Oracle handles are released on every path. The statement is closed as soon as the result is exhausted or when DuckDB
  destroys the scan state (`LIMIT`, errors, cancellation), and the session is closed when the query is destroyed. LOBs are fetched
  inline (as LONG), so no LOB locators are ever handed out.
* Oracle errors become DuckDB errors that include the code, for example
  `Binder Error: duckdb_oracle: connect failed: ORA-12541: TNS:no listener` or
  `duckdb_oracle: Oracle client library could not be loaded: DPI-1047: ...`.

## `oracle_client_info`

```sql
SELECT * FROM oracle_client_info();
```

Table function that returns one row and never fails. It is the first thing to run when something is wrong.

| Column | Meaning |
|---|---|
| `client_library_found BOOLEAN` | whether the Oracle client could be loaded (the first call triggers the lazy load) |
| `client_version VARCHAR` | for example `19.26.0.0.0`, NULL if no client |
| `client_library_path VARCHAR` | full path of the loaded `oci.dll` / `libclntsh.so` |
| `process_arch VARCHAR` | architecture of this DuckDB process / extension (`x64`, `arm64`) |
| `host_arch VARCHAR` | the machine's native architecture (`arm64` for an x64 DuckDB emulated on Windows ARM) |
| `odpi_version VARCHAR` | `26.0.0` (the version of the bundled Oracle client wrapper, ODPI-C) |
| `duckdb_oracle_version VARCHAR`, `duckdb_capi_version VARCHAR` | build info |
| `message VARCHAR` | `OK`, or the full `DPI-1047` text explaining what was searched, plus a `hint:` on Windows for architecture problems (see [COMPATIBILITY.md](COMPATIBILITY.md#windows-on-arm)) |

## Environment variables

| Variable | Used for |
|---|---|
| `ORACLE_USER` | default for `user :=` |
| `ORACLE_PASSWORD` | the password (or the variable named by `password_env :=`) |
| `DUCKDB_ORACLE_CLIENT_LIB_DIR` | Windows: load the Oracle client from exactly this directory (see [COMPATIBILITY.md](COMPATIBILITY.md#how-windows-finds-oracles-ocidll)); on Linux it is passed to the loader as the client library directory |
| `TNS_ADMIN` | directory of `tnsnames.ora` / `sqlnet.ora` / wallet, for TNS aliases |
| `LD_LIBRARY_PATH` | Linux: where `libclntsh.so` is found |
| `PATH` | Windows: where `oci.dll` is found |
| `DPI_DEBUG_LEVEL` | set to `64` before starting DuckDB to trace how the Oracle client library is searched |

## Errors

| Message contains | Meaning |
|---|---|
| `DPI-1047: Cannot locate a 64-bit Oracle Client library` | Instant Client not found, or the only `oci.dll` found has the wrong architecture. On Windows the text lists what was searched and any skipped `oci.dll` with its architecture |
| `DPI-1072`, `oci.dll was loaded from ...` | `oci.dll` loaded but the rest of Instant Client is missing next to it |
| `was found but Windows could not load it (error 126 ...)` | a DLL that `oci.dll` depends on is missing, usually the Visual C++ runtime |
| `no user given` / `no password given: the environment variable ... is empty or not set` | credentials missing; see [`oracle_query`](#oracle_query) |
| `Invalid named parameter "password"` | the inline password argument was removed |
| `ORA-12541`, `ORA-12514`, `ORA-12154` | listener not running, unknown service name, unresolvable TNS alias |
| `ORA-01017` | wrong user or password |
| `ORA-12170` (with a hint) | the connect timeout was reached; raise `connect_timeout :=` |
| `DPI-1067` (with a hint) | the call timeout was reached; raise `timeout :=` |
| `oracle_query only runs queries` | the statement was not a `SELECT` / `WITH` |
| `NUMBER value ... cannot be represented exactly as DOUBLE` | see [Unconstrained NUMBER](TYPES.md#unconstrained-number) |
| `has unsupported Oracle type` | see the last row of the [type table](TYPES.md) |

## Known limitations

* The file must be named `duckdb_oracle.duckdb_extension`, because DuckDB derives the init symbol from it. Releases are
  zips for that reason (see [COMPATIBILITY.md](COMPATIBILITY.md#which-zip-do-i-need)).
* The extension is unsigned, so `-unsigned` is required.
* Read-only: only `SELECT` / `WITH` queries run. DDL, DML, PL/SQL and `SELECT ... FOR UPDATE` are refused.
* Each `oracle_query` call opens its own Oracle session during bind, and keeps it until the query
  (or prepared statement) is destroyed. There is no pooling. The query is parsed twice
  (describe, then execute), and the second parse is a soft parse.
* Scans are single-threaded (one Oracle cursor).
* All columns are fetched: there is no projection or filter pushdown, so filter inside the Oracle SQL.
* Strings that are not valid UTF-8 become NULL on DuckDB versions whose string-assignment call validates UTF-8 (v1.5.6 does; older
  releases may not). With UTF-8 client encoding this should not happen.
* `TIMESTAMP WITH TIME ZONE` region names are lost, because DuckDB stores UTC instants.
* Interrupting (Ctrl+C) does not cancel an Oracle call: the C Extension API gives a table function no way to
  observe an interrupt while it is blocked in the Oracle client, so it only takes effect between fetches. A server that accepts
  the connection and never answers used to hang the session forever (verified with a silent TCP listener, two
  interrupts ignored). `connect_timeout` (default 30 s) and `timeout` (default 600 s per round trip) now bound that.
  The call timeout has not been exercised against a live server.
* Bind does not expose Oracle bind variables. Build the SQL text yourself, taking care with quoting.
* No catalog integration (`ATTACH`), no writes, and no DuckDB secrets. See [ROADMAP.md](ROADMAP.md).
