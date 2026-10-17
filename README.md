# duckdb-oracle

`duckdb_oracle` is a loadable DuckDB extension that runs queries on Oracle Database
(tested target: Oracle 19c) and returns the results as DuckDB tables.

* It is written in **Zig** against DuckDB's **stable C Extension API** (ABI type `C_STRUCT`).
  There is no C++ ABI between DuckDB and the extension, so a C++ entrypoint mismatch between
  extension and DuckDB build cannot happen here.
* It accesses Oracle through **ODPI-C** (vendored, compiled by Zig). ODPI-C loads `oci.dll` /
  `libclntsh.so` **at run time**. You need no Oracle SDK, headers or import
  libraries to build it. `LOAD` works without Instant Client, and you only get an error when an
  Oracle function actually runs.
* Windows is the primary target (`windows_amd64`) and Linux is secondary (`linux_amd64`). There is also a
  `windows_arm64` build, but on Windows ARM read [Windows on ARM](#windows-on-arm) first.
  `zig build` cross-compiles both from any host.

## Pinned versions

| Component | Version | Where |
|---|---|---|
| Zig | **0.15.2** default (`mise.toml`), supported 0.15.2 .. 0.17.x (tested 0.15.2 and 0.17.0) | `build.zig.zon` (`minimum_zig_version`), `mise.toml`, CI matrix |
| DuckDB headers / tested baseline | **v1.5.6** (source_id `069cc9f9b5`) | C API headers vendored in `third_party/duckdb/v1.5.6/` |
| Target C API version (footer + `get_api`) | **v1.2.0** by default = minimum DuckDB version; `-Dduckdb-version=vX.Y.Z` to change | `build.zig` |
| ODPI-C | **v26.0.0** (git tag) | `third_party/odpi/` |
| Footer writer | `append_extension_metadata.py` from duckdb/extension-ci-tools branch **v1.5.6**, unmodified | `third_party/extension-ci-tools/` |
| SQLLogicTest runner | duckdb-sqllogictest-python @ `2ac8dbc0` (same pin as extension-ci-tools) + `duckdb==1.5.6` wheel | CI |
| Oracle Instant Client | tested on Linux: **Basic 19.26.0.0.0** (`instantclient-basic-linux.x64-19.26.0.0.0dbru.zip`) and **Basic 23.26.2.0.0** (the 23ai/26ai-generation client; what Oracle's "latest" permalink `instantclient-basic-linuxx64.zip` served on 2026-10-17, sha256 `4c17d54d…ea05`). Windows: x64 Basic 19.26 (owner's machine) or 23ai/26ai | runtime only |

## Build

Requirements: Zig 0.15.2 – 0.17.x and Python 3, which runs the footer script. Nothing else is required: no
Oracle SDK, no MSVC, no CMake.

```sh
zig build                        # default platforms, ReleaseSafe, C API target v1.2.0
#  -> zig-out/linux_amd64/duckdb_oracle.duckdb_extension
#  -> zig-out/windows_amd64/duckdb_oracle.duckdb_extension
#  -> zig-out/windows_arm64/duckdb_oracle.duckdb_extension   (aarch64-windows-gnu)
#  -> zig-out/dist/duckdb_oracle-<platform>.zip               (shipped form, one per platform)
zig build -Dplatform=windows_amd64        # just one
zig build -Dplatform=linux_amd64_gcc4     # Linux binary labelled for DuckDB v1.2.x Linux CLIs
zig build -Dduckdb-version=v1.4.0         # target a specific (minimum) DuckDB version
zig build test                            # Zig unit tests (type conversion)
zig build sqllogictest -Dpython=.venv/bin/python   # SQLLogicTests, needs duckdb (1.5.6 tested) + runner
python3 tools/verify_artifact.py check zig-out/dist/duckdb_oracle-linux_amd64.zip --platform linux_amd64 \
    --duckdb ./duckdb --client none --client /path/to/instantclient_19_26   # name rule, footer, stock-CLI load, negative control, client checks
python3 tools/verify_artifact.py check zig-out/dist/duckdb_oracle-windows_amd64.zip --platform windows_amd64   # name rule, footer, PE machine/exports/imports
python3 tools/verify_artifact.py check zig-out/dist/duckdb_oracle-windows_amd64.zip --platform windows_amd64 \
    --duckdb duckdb.exe --wine wine64      # the official Windows CLI under Wine (a stand-in for Windows)
python3 -m unittest discover -s tools     # the verifier's own tests (it must FAIL on bad artifacts)
```

Options: `-Doptimize=Debug|ReleaseSafe|ReleaseFast`, `-Dextension-version=v0.1.0`
(the default comes from `git describe`, so an untagged build reports a commit hash such as `042dc85`; build releases from a tag), `-Dduckdb-version=vX.Y.Z` (see below; `-Dcapi-version`
is a deprecated alias), and `-Dpython=python3`.

## Distribution: one zip per platform

DuckDB derives the extension name, and the init symbol it resolves (`<name>_init_c_api`), from the
**file name**. The file therefore has to be called exactly `duckdb_oracle.duckdb_extension`. A platform
suffix in the file name breaks `LOAD` with `did not contain function "duckdb_oracle-<platform>_init_c_api"`.
So each platform ships as a zip, with the platform in the zip name only:

| Download | Contains | For |
|---|---|---|
| `duckdb_oracle-windows_amd64.zip` | `duckdb_oracle.duckdb_extension` | Windows x64, and Windows ARM through x64 emulation |
| `duckdb_oracle-windows_arm64.zip` | `duckdb_oracle.duckdb_extension` | native Windows ARM64 DuckDB (see Windows on ARM) |
| `duckdb_oracle-linux_amd64.zip` | `duckdb_oracle.duckdb_extension` | Linux x86-64, DuckDB 1.3+ |
| `duckdb_oracle-linux_amd64_gcc4.zip` | `duckdb_oracle.duckdb_extension` | Linux x86-64, DuckDB 1.2.x (platform `linux_amd64_gcc4`) |

Unzip the archive and load the file exactly as unzipped. Don't rename it. `zig build` writes the zips to
`zig-out/dist/` using `tools/package.py`, which owns the shipped name and refuses any other inner name.
`tools/verify_artifact.py` is the one place that checks the rules: it takes the **zip**, extracts the file unchanged,
and fails on a zip whose only entry isn't `duckdb_oracle.duckdb_extension` or on a misnamed file; it also runs a
negative control (a platform-suffixed copy must fail to load). CI, `tools/timeout-test.sh` and
`tools/windows-locator-test.sh` all go through it. `test-windows.ps1` is deliberately standalone (it ships next to
the zip and needs no Python), so it keeps its own copy of the unpack check.

## Zig versions

The same source tree builds and passes its tests on **Zig 0.15.2 through 0.17.x**. Both ends were
verified: 0.15.2 and 0.17.0. There are no per-version branches or copies.

* `build.zig.zon` sets `minimum_zig_version = "0.15.2"`. `mise.toml` pins the default toolchain to **0.15.2**,
  which also builds the released artifacts.
* All differences between the Zig versions are confined to two files:
  * `build_compat.zig` (build script):
    * `OptimizeMode` field names: 0.17 renamed them to `debug`/`safe`/`fast`/`small`. `-Doptimize=` accepts both
      spellings on every version.
    * `Step.Run.captureStdOut` gained an options argument in 0.17.
    * `Build.build_root` became `Build.root` in 0.17.
    * `runAllowFail`'s stdio enum changed in 0.17.
    * `std.builtin.Type.Fn.params` became `param_types` in 0.17.
  * `src/compat.zig` (extension):
    * `std.Thread.Mutex` was removed in 0.17; the replacement `std.Io.Mutex` needs an `Io`.
    * `fmt.bufPrintZ` and `Allocator.dupeZ` were removed in 0.17.
    * `process.getEnvVarOwned` was removed in 0.16, and environment access moved to `main`'s `Environ`. duckdb-oracle now
      reads the environment through a tiny C helper instead.
* The shims detect features with `@hasDecl`, `@hasField` and `@typeInfo`. None of them needs `builtin.zig_version`.
* `@cImport` was removed in 0.17. The C headers (`src/c_headers.h`) are now translated by the build system
  (`b.addTranslateC`), which works the same on all supported versions.
* CI runs build, unit tests, the stock-DuckDB load test, the client matrix and the SQLLogicTests on both
  0.15.2 and 0.17.0.

```sh
mise install && zig build && zig build test     # default (0.15.2)
/path/to/zig-0.17.0/zig build && /path/to/zig-0.17.0/zig build test
```

## Supported DuckDB versions

The extension uses only the **stable** C Extension API (ABI type `C_STRUCT`). For this ABI type,
the footer does **not** record a specific DuckDB release. Its version field holds the **minimum
C API version**, and DuckDB accepts the file on any 1.x release at or above it. Every function duckdb-oracle calls
is in the v1.2.0 stable surface, so the default build targets **v1.2.0**, the first release with the C
Extension API. **v1.5.6 is the tested baseline**: its headers are vendored and the full test suite ran against it.

| Official DuckDB CLI | linux_amd64 (default build) | windows_amd64 (default build) |
|---|---|---|
| v1.5.0 – v1.5.6 (newest at time of writing) | ✅ loaded (tested v1.5.0, v1.5.6) | ✅ v1.5.6 under Wine; CI matrix |
| v1.3.x, v1.4.x | ✅ loaded (tested v1.3.2, v1.4.5) | CI matrix (v1.3.2, v1.4.5) |
| v1.2.x | ⚠️ these Linux CLIs report platform `linux_amd64_gcc4`. Use the `-Dplatform=linux_amd64_gcc4` build: the library bytes are identical and only the footer label differs. Alternatively, load the unchanged file after `SET allow_extensions_metadata_mismatch=true;`. Both tested on v1.2.0 and v1.2.2 | ✅ v1.2.0 under Wine; CI matrix |
| ≤ v1.1.x | ❌ no C Extension API. Rejected cleanly ("built for DuckDB C API version 'v1.2.0'") | ❌ |
| 2.x (does not exist yet) | ❌ C API major version must be 1 | ❌ |

To build for a specific DuckDB version, run `zig build -Dduckdb-version=v1.4.0`. That binary loads on
1.4.0 and newer 1.x releases. Allowed values run from `v1.2.0` to `v1.5.6`, the vendored headers. Because
the headers gate every function by version, targeting an older version makes any use of a newer API a
compile error, so the build itself proves the minimum version is correct. Supporting releases newer than 1.5.6
needs no rebuild: the default binary already loads there (forward compatibility of the stable C API).
Targeting a C API *above* 1.5.6 would mean vendoring that release's headers into
`third_party/duckdb/<ver>/` and updating `duckdb_headers_version` in `build.zig`.

On Windows the build uses `python` instead of `python3` (`-Dpython=` overrides this).

### Why `x86_64-windows-gnu`

Only a plain C ABI crosses the DuckDB ↔ extension boundary: the `duckdb_extension_access`
struct and the versioned function-pointer struct. No C++ objects, exceptions or STL types
cross it, so the MSVC requirement for C++ DuckDB extensions does not apply. Zig ships the
MinGW-w64 CRT and builds it against the Windows UCRT. The resulting DLL imports only
`KERNEL32.dll`, `ntdll.dll` and the `api-ms-win-crt-*` UCRT API sets, which are part of
Windows 10 and later (`tools/verify_artifact.py` enforces this). No libgcc, libstdc++ or
vcruntime DLL is needed. The footer platform is the standard `windows_amd64`, which the
official CLI accepts. `windows_amd64_mingw` exists only for C++-ABI extensions built for
MinGW DuckDB builds.

## Windows on ARM

**Oracle does not publish an Instant Client for Windows ARM64**, as far as could be determined on
2026-10-17. Windows downloads exist for x64 and 32-bit x86 only, and ARM64 builds exist only for Linux and macOS.
REPORT.md section 8.3 has the evidence. A native ARM64 process
cannot load an x64 `oci.dll`. As a result, the `windows_arm64` duckdb-oracle build loads fine into the
native ARM64 DuckDB CLI, but `oracle_query()` can never connect from that process.

**What to use on a Windows ARM64 machine:** the **x64** DuckDB CLI (`duckdb_cli-windows-amd64.zip`), the
**`windows_amd64`** extension and the **x64** Instant Client, plus the x64 Visual C++ redistributable.
Windows runs all three under its built-in x64 emulation, and this works the same way as on an Intel/AMD PC.

| duckdb.exe | extension | oci.dll | result |
|---|---|---|---|
| x64 (emulated on ARM64) | windows_amd64 | x64 | ✅ supported setup |
| ARM64 (native) | windows_arm64 | x64 | `LOAD` works; Oracle calls fail: DPI-1047 plus a hint |
| ARM64 | windows_amd64 (or the other way round) | any | `LOAD` fails: the DLL architecture doesn't match |

The diagnostics cover this case. `oracle_client_info()` reports `process_arch` and `host_arch`, and when the
client is missing it appends a hint to `message`. In a native ARM64 process the hint says exactly the
above. When an x64 DuckDB is emulated on ARM64, the hint (or the `OK (...)` note) says so. It also names the
architecture of the first `oci.dll` on the search path when that doesn't match the process.
`test-windows.ps1` detects an ARM64 host and checks that duckdb.exe, the extension and the first
`oci.dll` all share one architecture, warning on any mismatch. It downloads the x64 CLI by default; use
`-DuckDBArch arm64` for the native one.

## Windows install walkthrough

1. **Install Oracle Instant Client Basic x64** (19c or 23ai) and unzip it, for example to
   `C:\oracle\instantclient_19_26`. Instant Client 19 also needs the VS 2017 (or later) x64
   C++ runtime.
2. **Put the 64-bit client first on `PATH`**:
   ```powershell
   $env:PATH = "C:\oracle\instantclient_19_26;$env:PATH"
   ```
   If a 32-bit client is also on `PATH`, it must come *after* the 64-bit one. Alternatively,
   pin the directory for duckdb-oracle only:
   ```powershell
   $env:DUCKDB_ORACLE_CLIENT_LIB_DIR = "C:\oracle\instantclient_19_26"
   ```
   On Windows the extension itself decides which `oci.dll` loads (`src/client_locator.zig`), in this order:
   `DUCKDB_ORACLE_CLIENT_LIB_DIR` (exclusively, if set), otherwise the extension's own directory, the directory
   of `duckdb.exe`, then each **absolute** entry of `PATH`. **The current directory and relative `PATH` entries
   are never searched**, so a stray `oci.dll` in the folder you start DuckDB from is not loaded. An `oci.dll` of the
   wrong architecture (for example a 32-bit client) is skipped and named in the message, and the search goes on, so
   the order of a 32-bit and a 64-bit client on `PATH` no longer matters. The path is handled as Unicode, so
   directories with non-ASCII characters work. `oracle_client_info()` reports where `oci.dll` was loaded from.
3. **Use a stock DuckDB CLI** (v1.2.0 or newer; v1.5.6 is the tested baseline), download
   `duckdb_oracle-windows_amd64.zip`, and unzip it. It contains exactly `duckdb_oracle.duckdb_extension`;
   keep that name. DuckDB derives the entrypoint symbol from the file name.
   ```powershell
   Expand-Archive .\duckdb_oracle-windows_amd64.zip -DestinationPath C:\path\to
   ```
4. **Start DuckDB with `-unsigned`** and load the extension:
   ```powershell
   duckdb -unsigned
   ```
   ```sql
   LOAD 'C:/path/to/duckdb_oracle.duckdb_extension';
   SELECT * FROM oracle_client_info();
   ```
   To install it once instead, run `INSTALL 'C:/path/to/duckdb_oracle.duckdb_extension';`. After that,
   `LOAD duckdb_oracle;` works in every `-unsigned` session.
5. **Set credentials in the environment**, not in SQL. DuckDB echoes the failing SQL line in
   error messages, and the CLI keeps a history:
   ```powershell
   $env:ORACLE_USER = 'SAMPLE_DEV'
   $s = Read-Host 'Oracle password' -AsSecureString
   $env:ORACLE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
       [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
   duckdb -unsigned -c "LOAD 'C:/path/to/duckdb_oracle.duckdb_extension'; SELECT * FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT * FROM dual');"
   ```
6. **Run the smoke test**: put `test-windows.ps1` next to `duckdb_oracle-windows_amd64.zip` and run
   `.\test-windows.ps1`. It unpacks the zip itself; `-Extension` also accepts a zip. See the script's help
   (`Get-Help .\test-windows.ps1 -Full`).
7. **Optional 23ai/26ai database** (for example `docker run -d -p 1522:1521 -e ORACLE_PASSWORD=... gvenzl/oracle-free`):
   set `$env:ORACLE_DSN_23AI = 'localhost:1522/FREEPDB1'`, `$env:ORACLE_PASSWORD_23AI` (falls back to
   `ORACLE_PASSWORD`) and optionally `$env:ORACLE_USER_23AI` (default `SYSTEM`), then rerun the script.
   Section 4 runs the 19c checks against that server and, if the loaded client is 23ai+, BOOLEAN/JSON/VECTOR
   checks; with a 19c client it skips them with a warning.

## SQL surface (v1)

### `oracle_query(dsn, sql, user := ..., password_env := ..., auth := ..., connect_timeout := ..., timeout := ...)`

Table function. It runs one Oracle query and returns its result set.

| Argument | Meaning |
|---|---|
| `dsn VARCHAR` | Easy Connect string such as `localhost:1521/ORCLPDB1`, or a TNS alias (`TNS_ADMIN`) |
| `sql VARCHAR` | An Oracle `SELECT` / `WITH` query, using Oracle SQL dialect. One trailing `;` is removed (Oracle rejects it). `SELECT ... FOR UPDATE` is refused: it takes row locks that would stay held for the life of the session |
| `user := VARCHAR` | Optional. Defaults to `$ORACLE_USER` |
| `auth := VARCHAR` | Optional. `'password'` (default) or `'external'`: Oracle wallet (`/@alias`), Kerberos or OS authentication, where no user or password is given. `user` and `password_env` are refused in external mode |
| `password_env := VARCHAR` | Optional. Name of the environment variable that holds the password. Defaults to `ORACLE_PASSWORD` |
| `unconstrained_number := VARCHAR` | Optional. How a `NUMBER` with no exact `DECIMAL` form is returned (see Type mapping): `'double'` (default, checked), `'lossy_double'` or `'varchar'` |
| `connect_timeout := BIGINT` | Optional. Seconds allowed for the connection handshake. Default **30**, `0` = no limit. Added to Easy Connect strings as `connect_timeout=N` unless the DSN already sets it; TNS aliases and `(DESCRIPTION=...)` strings are used unchanged (set it in `sqlnet.ora`/the descriptor) |
| `timeout := BIGINT` | Optional. Seconds allowed for each Oracle round trip on the session (describe, execute, every fetch), via `dpiConn_setCallTimeout`. Default **600**, `0` = no limit. A query that legitimately takes longer than this before returning its first row needs a larger value |

**There is no `password` argument, on purpose.** DuckDB echoes the failing SQL text, literals included, in error
messages (for example a wrong password, ORA-01017) and the CLI keeps a history, so a password written in SQL leaks.
The password is read from the environment only. `password := '...'` from earlier versions is now rejected with
`Invalid named parameter "password"`; set `ORACLE_PASSWORD` (or the variable named by `password_env`) instead.

```sql
SELECT * FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT owner, table_name FROM all_tables');
SELECT * FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT * FROM dual', user := 'SAMPLE_DEV');
CREATE TABLE t AS SELECT * FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT * FROM aims.orders');
```

How it works:

* **Bind** connects (one Oracle session per `oracle_query` call), checks that the
  statement is a query (DDL, DML and PL/SQL are refused before anything executes), describes it
  with `DPI_MODE_EXEC_DESCRIBE_ONLY`, and maps the columns.
* **Init** prepares and executes the statement and defines one ODPI-C variable per
  column with array size = `duckdb_vector_size()` (2048).
* **Scan**: each `dpiStmt_fetchRows` call fills one DuckDB chunk (array fetch). If one batch
  would need more than 64 MiB of fetch buffers (very wide rows), duckdb-oracle fetches fewer rows per chunk.
* All ODPI-C handles are released on every path. The statement is closed as soon as the result is
  exhausted or when DuckDB destroys the scan state (`LIMIT`, errors, cancellation), and the session is
  closed when the bind data is destroyed. LOBs are fetched inline (as LONG), so no LOB locators
  are ever handed out.
* Oracle and ODPI-C errors become DuckDB errors that include the code, for example
  `Binder Error: duckdb_oracle: connect failed: ORA-12541: TNS:no listener` or
  `duckdb_oracle: Oracle client library could not be loaded: DPI-1047: ...`.

### `oracle_client_info()`

Table function that returns one row and never fails. It is the first thing to run when something is wrong.

| Column | Meaning |
|---|---|
| `client_library_found BOOLEAN` | whether OCI could be loaded (the first call triggers the lazy load) |
| `client_version VARCHAR` | for example `19.26.0.0.0`, NULL if no client |
| `client_library_path VARCHAR` | full path of the loaded `oci.dll` / `libclntsh.so` |
| `process_arch VARCHAR` | architecture of this DuckDB process / extension (`x64`, `arm64`) |
| `host_arch VARCHAR` | the machine's native architecture (`arm64` for an x64 DuckDB emulated on Windows ARM) |
| `odpi_version VARCHAR` | `26.0.0` |
| `duckdb_oracle_version VARCHAR`, `duckdb_capi_version VARCHAR` | build info |
| `message VARCHAR` | `OK`, or the full `DPI-1047` text explaining what was searched, plus a `hint:` on Windows for architecture problems (see Windows on ARM) |

## Type mapping

| Oracle | DuckDB | Notes |
|---|---|---|
| `NUMBER(p,0)`, p ≤ 18 (also `NUMBER(p,-s)` with p+s ≤ 18) | `BIGINT` | fetched as int64 |
| `NUMBER(p,s)`, s > 0, max(p,s) ≤ 38; `NUMBER(19..38,0)` | `DECIMAL(max(p,s), s)` | exact: fetched as text, parsed to the scaled integer, stored as int16/32/64/128 |
| `NUMBER` (no precision), `FLOAT(b)`, `NUMBER(p,-s)` with p+s > 38, `NUMBER(p,s)` wider than 38 | `DOUBLE` (checked) | Oracle reports expressions such as `COUNT(*)` or `1/3`, and bare `NUMBER` columns, as unconstrained, so these arrive as `DOUBLE`. They are fetched as text and an **integral value a double cannot hold exactly (for example `9007199254740993`) is an error**, not a silently rounded number. Fractions are approximate, as in any `DOUBLE`. Use `CAST(x AS NUMBER(p,s))` in the Oracle SQL for exact types, or `unconstrained_number := 'varchar'` for exact text, or `'lossy_double'` for the previous silently-rounding behaviour |
| `BINARY_DOUBLE` | `DOUBLE` | |
| `BINARY_FLOAT` | `FLOAT` | |
| `VARCHAR2`, `NVARCHAR2`, `CHAR`, `NCHAR` | `VARCHAR` | UTF-8 (ODPI-C `encoding`/`nencoding` = UTF-8). `CHAR` keeps Oracle's blank padding |
| `CLOB`, `NCLOB`, `LONG` | `VARCHAR` | fetched inline as LONG (`DPI_ORACLE_TYPE_LONG_(N)VARCHAR`) |
| `XMLTYPE` | `VARCHAR` | |
| `ROWID`, `UROWID` | `VARCHAR` | `dpiRowid_getStringValue` |
| `DATE`, `TIMESTAMP(n)` | `TIMESTAMP` | microsecond precision (fractional nanoseconds are truncated) |
| `TIMESTAMP WITH TIME ZONE`, `TIMESTAMP WITH LOCAL TIME ZONE` | `TIMESTAMPTZ` | converted to UTC with the offset ODPI-C returns. Region names are not preserved |
| `RAW`, `LONG RAW`, `BLOB` | `BLOB` | |
| `INTERVAL DAY TO SECOND` / `YEAR TO MONTH` | `INTERVAL` | |
| `BOOLEAN` (23ai+ server, 23ai+ client) | `BOOLEAN` | |
| `JSON` (21c+ native type; 21c+ client) and `BLOB ... IS JSON (FORMAT OSON)` | `VARCHAR` (JSON text) | fetched as a `dpiJson` tree (`dpiJson_getValue`, numbers as exact decimal text) and serialised in Zig to compact JSON. Non-JSON scalars follow `JSON_SERIALIZE` conventions: RAW → uppercase hex string, DATE/TIMESTAMP → ISO 8601 string, INTERVAL → ISO 8601 duration, NaN/±Inf → strings. Key order is whatever OSON returns. Use DuckDB's `json_*` functions on the result |
| `VECTOR(n, FLOAT32)` (23ai+ server and client) | `FLOAT[]` | |
| `VECTOR(n, FLOAT64)` | `DOUBLE[]` | |
| `VECTOR(n, INT8)` | `FLOAT[]` | int8 → float is exact |
| `VECTOR(*, *)` (flexible format) | `DOUBLE[]` | each value converted from its own storage format |
| `VECTOR(n, BINARY)` | `UTINYINT[]` | the packed bytes, n/8 elements (the brief only named FLOAT/DOUBLE; a float list of bits would be misleading) |
| sparse `VECTOR` (23.7+) | same as dense | densified (zeros for absent dimensions); rejected above 16M elements |
| `OBJECT`, `BFILE`, `REF CURSOR`, other | bind-time error | `duckdb_oracle: column N ("X") has unsupported Oracle type OBJECT; convert it in the query, e.g. TO_CHAR(...) or JSON_SERIALIZE(...)` |

NULLs map to DuckDB NULLs for every type. On a 19c server none of the 23ai rows can occur,
so 19c behaviour is unchanged (the 19c mappings and their unit tests are untouched).

**Client requirements for 23ai/26ai types.** The server types only reach duckdb-oracle if the Oracle
client understands them: `BOOLEAN` and `VECTOR` need Instant Client **23ai or newer**, native
`JSON` needs **21c or newer**. With the 19.26 client against a 23ai server, plain 19c-style
queries work, but a column of those types is expected to fail at bind time with an Oracle/ODPI-C
error or the "unsupported Oracle type" message (expected behaviour, not verified against a server). Workaround with an old client:
`JSON_SERIALIZE(col)`, `FROM_VECTOR(col)`, `CASE WHEN b THEN 1 ELSE 0 END`.

## Troubleshooting

* `DPI-1047: Cannot locate a 64-bit Oracle Client library`: Instant Client is not found, or the
  first `oci.dll` is 32-bit. See step 2 above. Run `test-windows.ps1`: it lists every
  `oci.dll` in load order along with its architecture.
* `did not contain function "duckdb_oracle-..._init_c_api"`: the file was renamed. Use the file from the zip,
  which is named exactly `duckdb_oracle.duckdb_extension`.
* `... is not signed`: start DuckDB with `-unsigned` (or `SET allow_unsigned_extensions = true`
  at startup).
* `ORA-12541` / `ORA-12514`: the listener or service is unreachable. Check the Docker port mapping and the
  service name (`ORCLPDB1`).
* On Windows, the `DPI-1047` text lists what was searched and any skipped `oci.dll` with its architecture. On Linux,
  set `DPI_DEBUG_LEVEL=64` before starting DuckDB to trace how ODPI-C searches for OCI.

## Known limitations

* The file must be named `duckdb_oracle.duckdb_extension`, because DuckDB derives the init symbol from it. Releases are
  zips for that reason (see Distribution).
* The extension is unsigned, so `-unsigned` is required.
* Each `oracle_query` call opens its own Oracle session during bind, and keeps it until the query
  (or prepared statement) is destroyed. There is no pooling. The query is parsed twice
  (describe, then execute), and the second parse is a soft parse.
* Scans are single-threaded (one Oracle cursor).
* All columns are fetched: there is no projection or filter pushdown, so filter inside the Oracle SQL.
* Strings that are not valid UTF-8 become NULL on DuckDB versions whose `duckdb_vector_assign_string_element_len`
  validates UTF-8 (v1.5.6 does; older releases may not). With UTF-8 client encoding this should not happen.
* `TIMESTAMP WITH TIME ZONE` region names are lost, because DuckDB stores UTC instants.
* Interrupting (Ctrl+C) does not cancel an Oracle call: the C Extension API gives a table function no way to
  observe an interrupt while it is blocked in OCI, so it only takes effect between fetches. A server that accepts
  the connection and never answers used to hang the session forever (verified with a silent TCP listener, two
  SIGINTs ignored). `connect_timeout` (default 30 s) and `timeout` (default 600 s per round trip) now bound that.
  The call timeout has not been exercised against a live server.
* Bind does not expose Oracle bind variables. Build the SQL text yourself, taking care with quoting.

## Future work

`ATTACH ... (TYPE oracle)` catalog integration; DuckDB secrets (`CREATE SECRET (TYPE oracle)`);
writes, DML and transactions; filter and projection pushdown; session pooling (ODPI-C
`dpiPool`); bind parameters; parallel scans (ROWID ranges); `dpiConn_breakExecution` on
interrupt; OBJECT type support; `JSON` → DuckDB `JSON` logical type (needs the json extension's type alias); macOS and linux_arm64 targets; an ARM64EC build (could load the x64 oci.dll in a native ARM64 process, but needs an ARM64EC toolchain and an ARM64EC DuckDB); a signed
community-extension distribution, which is blocked by the proprietary OCI runtime dependency.

## Layout

```
build.zig, build.zig.zon     Zig build (cross-compile + footer + tests)
build_compat.zig             Zig-version shims for the build script (0.15.2 .. 0.17.x)
src/compat.zig               Zig-version shims for the extension code
src/c_headers.h              C headers translated by b.addTranslateC (module "c_headers")
mise.toml                    default Zig toolchain (0.15.2)
src/duckdb_oracle.zig              entrypoint (duckdb_oracle_init_c_api), table functions, DuckDB vectors
src/session.zig              one session: credentials, auth mode, connect + timeouts, read-only SQL guard, describe (+ policy tests)
src/oracle.zig               lazy ODPI-C context, error formatting, client info
src/cursor.zig               result-set lifetime: statement, fetch variables, early close; generic over a backend (+ tests with an in-memory backend)
src/odpi_backend.zig         the ODPI-C adapters: backend for cursor.zig, handle reader for column.zig
src/timeouts.zig             connect/call timeout policy (+ unit tests)
src/column.zig               what an Oracle column becomes in DuckDB: type plan, fetch cost, value write behind a vector-sink seam (+ tests)
src/convert.zig              pure value primitives: timestamps, decimals, NUMBER-as-double check, JSON text, VECTOR copy (+ unit tests)
src/c.zig                    C headers module (src/c_headers.h via b.addTranslateC)
src/client_locator.zig       which oci.dll loads (Windows search policy + diagnostics), behind an OS seam (+ tests with a fake OS)
src/platform.c               Windows locator primitives (wide-char load, PE machine, directories), loaded OCI path, host architecture, getenv
src/arch.zig                 process/host architecture + Windows-on-ARM hints (+ unit tests)
test/sql/*.test              SQLLogicTests (no-client paths)
tools/windows-locator-test.sh Windows client-locator scenarios with the real Windows duckdb.exe + Instant Client (Wine or Windows)
tools/verify_artifact.py     the artifact rules in one place: name, footer, PE, stock-CLI load, negative control, client checks (+ tests)
tools/                       package.py (zip packaging, owns the shipped name), pe_inspect.py (x64+ARM64), check_footer.py, timeout-test.sh
test-windows.ps1             Windows smoke test (stock CLI, oci.dll check, Oracle container)
third_party/                 vendored DuckDB headers, ODPI-C, metadata script (see VERSIONS.md)
.github/workflows/ci.yml     Linux build + tests, Windows stock-CLI load tests
```

## Licenses

duckdb-oracle is MIT licensed (`LICENSE`). Vendored code keeps its own licenses:
ODPI-C is under UPL-1.0 / Apache-2.0 (`third_party/odpi/LICENSE.txt`). The DuckDB headers and
extension-ci-tools script are MIT.
