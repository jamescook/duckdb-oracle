# duckdb-oracle: verification report

> **Note added after an independent review (see the git log).** This report records the verification of v0.6.1 and is kept as
> history; it is not updated. Behaviour described below that has since changed: `oracle_query(..., password := ...)` was removed
> in favour of `password_env`/`ORACLE_PASSWORD` (section 3.2, "Credentials"); unconstrained `NUMBER` is still `DOUBLE` but integers a
> double cannot hold exactly are now an error (type mapping; `unconstrained_number`); connect and call timeouts exist (`connect_timeout`,
> `timeout`); on Windows the extension now chooses `oci.dll` itself and never searches the current directory; the shell load tests were
> replaced by `tools/verify_artifact.py`. The README is authoritative for current behaviour. `evidence.txt` and
> `evidence-history.txt` named below were never committed to this repository.


Run date: 2026-10-17. Sandbox: Ubuntu 24.04 x86_64, no Oracle server, no Docker.
**Updates:**
* v0.2.0 added support for Oracle 23ai/26ai (section 6).
* v0.3.0 made the extension portable across DuckDB versions (section 7). The default C API target is now v1.2.0.
* v0.4.0 added windows_arm64 (section 8).
* v0.5.0 added support for Zig 0.15.2 through 0.17.x (section 9).
* v0.6.0 renamed the project to duckdb-oracle; the extension is now `duckdb_oracle` (section 10).
* **v0.6.1 ships each platform as `duckdb_oracle-<platform>.zip` containing exactly `duckdb_oracle.duckdb_extension` (section 11).**

Wherever sections 1–6 say the footer records `v1.5.6`, they describe the older builds. Sections 1–9 were updated
mechanically to the new name, but the runs they describe used binaries built under the project's former name. Their
raw logs, kept verbatim, are in `evidence-history.txt`.

Deliverables are built from git tag **v0.6.1** of the repo in `duckdb-oracle-src.tar.gz`, using Zig 0.15.2.
Each platform ships as a zip that contains exactly one file, `duckdb_oracle.duckdb_extension` (section 11).

| Download (v0.6.1) | SHA-256 of the zip | SHA-256 of the `duckdb_oracle.duckdb_extension` inside |
|---|---|---|
| `duckdb_oracle-linux_amd64.zip` | `eb9ac1ab8ad341c8e07eae1f83fca4254fa94ef72aeeb7cb30033346ab2b24c1` | `fda1134349ca0d2347342f0443f94c176872593a46c8acf0532af61a72ba938a` |
| `duckdb_oracle-linux_amd64_gcc4.zip` (DuckDB v1.2.x Linux) | `29033a2566a0b0971a6c9832a97ff2baeca6e51f2bdac7d429711eabb0f13b26` | `3a45fc1f27788cc4d12011042d499d18d7a8d4f39f93d0c0a95e32d498e846ec` |
| `duckdb_oracle-windows_amd64.zip` | `530685db696cfe24c7adff15899536221fc2e7b005437c08abcfd0045bd3d7bb` | `d717de6552f28d0584c23d4acebc792894793e2a8d9b0b70c18e6b4bd7190bc1` |
| `duckdb_oracle-windows_arm64.zip` (see section 8) | `e39adbd6e7257c88853abee2f7667fc054789987f1b2e7a0414a0cbb7e5fe7dd` | `35c7fa6f9a6a37f44f960259decb21baf207fded94e808e290c8d58ab166fbec` |

**Releases ship as `duckdb_oracle-<platform>.zip`, each containing exactly `duckdb_oracle.duckdb_extension`; load that file without renaming it** (section 11).

The full logs for sections 1–9 are in `evidence-history.txt`. Sections 10 and 11 are logged in `evidence.txt`.

---

## 1. Summary

* The extension is written in Zig 0.15.2 against the stable C Extension API, ABI type `C_STRUCT`,
  using DuckDB v1.5.6 headers. It uses ODPI-C v26.0.0, which is vendored and compiled by Zig. OCI is
  loaded lazily when an Oracle function is first called.
* All five acceptance checks ran. 1–4 pass in this sandbox. For check 5, the SQLLogicTests and Zig
  unit tests pass. The details and limits are in section 2.
* **Nothing in this sandbox could fetch real rows from Oracle.** The query path after connect
  (describe, define, array fetch, value conversion, LOB-as-LONG, ROWID) has **never run against a
  database**. Only the pure conversion functions are unit-tested, with hand-built `dpiData`.
  The first real exercise of that path will be `test-windows.ps1` against your 19c container.
* Two real defects turned up and were fixed during the work (section 3.1). One of them would
  have hung DuckDB on Windows the first time an Oracle function was called. That one was found
  under Wine.

## 2. Acceptance checks

### Check 1: `zig build` produces both artifacts. PASS

These commands ran in a fresh `git clone` of the repo at tag v0.1.0:
```
$ zig version                      -> 0.15.2
$ zig build --summary all          -> Build Summary: 9/9 steps succeeded   exit=0
  zig-out/v1.5.6/linux_amd64/duckdb_oracle.duckdb_extension    (425,790 bytes, ELF x86-64 .so)
  zig-out/v1.5.6/windows_amd64/duckdb_oracle.duckdb_extension  (448,534 bytes, PE32+ x86-64 DLL)
$ zig build test --summary all     -> 10/10 tests passed                   exit=0
```
The build needs no network access (everything is vendored), no Oracle SDK, no MSVC and no CMake.
The vendored `append_extension_metadata.py` from extension-ci-tools branch `v1.5.6` writes the
footer **unmodified**, with `--abi-type C_STRUCT --duckdb-version v1.5.6 --duckdb-platform <p>`.
I read it back with `tools/check_footer.py`. That tool mirrors
`ExtensionHelper::ParseExtensionMetaData` from the v1.5.6 amalgamation: it takes the last 512 bytes,
treats them as 8×32-byte fields stored in reverse order, then a 256-byte signature area.

### Check 2: stock Linux CLI loads the extension with no Instant Client. PASS

* CLI: official `duckdb_cli-linux-amd64.zip` v1.5.6 from GitHub releases
  (sha256 `6e89deac…5e2f`). It reports `v1.5.6 (Variegata) 069cc9f9b5`.
* No client was present: `ldconfig -p | grep -c libclntsh` returned 0, `LD_LIBRARY_PATH` was unset, and libaio was not installed.
* duckdb-oracle is not built in. Before `LOAD`, `duckdb_extensions()` has 0 `duckdb_oracle` rows and
  `duckdb_functions()` has 0 `oracle_%` functions. `tools/stock-cli-test.sh` asserts this.

```
$ duckdb -unsigned -c "LOAD '<path>/duckdb_oracle.duckdb_extension'; SELECT * FROM duckdb_extensions() WHERE extension_name='duckdb_oracle'; SELECT * FROM oracle_client_info();"
  extension_name=duckdb_oracle loaded=true installed=false extension_version=v0.1.0 install_mode=NOT_INSTALLED
  client_library_found=false client_version=NULL client_library_path=NULL odpi_version=26.0.0
  message=DPI-1047: Cannot locate a 64-bit Oracle Client library: "libclntsh.so: cannot open shared object file: No such file or directory". See https://www.oracle.com/database/technologies/instant-client.html for help
exit=0
$ tools/stock-cli-test.sh duckdb duckdb_oracle.duckdb_extension      -> PASS, exit=0
```
Without a client, `oracle_query(...)` raises
`Binder Error: duckdb_oracle: Oracle client library could not be loaded: DPI-1047: ...` and the CLI exits with code 1, which is the normal exit for an error.

### Check 3: with Instant Client present. PASS

* Installed `instantclient-basic-linux.x64-19.26.0.0.0dbru.zip` from download.oracle.com
  (sha256 `f5f5f7e8…339e`) into `/opt/oracle/instantclient_19_26`. Installed `libaio1t64` and added the
  `libaio.so.1` symlink that Ubuntu 24.04 needs. Set `LD_LIBRARY_PATH` to the client directory.

```
$ duckdb -unsigned -line -c "LOAD ...; SELECT * FROM oracle_client_info();"
  client_library_found=true client_version=19.26.0.0.0
  client_library_path=/opt/oracle/instantclient_19_26/libclntsh.so message=OK          exit=0
$ duckdb -unsigned -c "LOAD ...; SELECT * FROM oracle_query('127.0.0.1:1/NOPE', 'SELECT * FROM dual', user := 'scott', password := 'x');"
  Binder Error: duckdb_oracle: connect failed: ORA-12541: TNS:no listener                     exit=1
$ ... oracle_query('nosuchhost.invalid:1521/X', ...)
  Binder Error: duckdb_oracle: connect failed: ORA-12154: TNS:could not resolve the connect identifier specified   exit=1
```
The process exits normally with DuckDB's error exit code 1. A crash would give 134 or 139.
When SQL is piped via stdin, the same CLI session keeps running after the Oracle error and
answers the next query (`evidence-history.txt`, section 15). The SQLLogicTests also pass with the client
present.

### Check 4: Windows artifact inspection. PASS (static inspection only)

`tools/check-pe.sh duckdb_oracle.duckdb_extension v1.5.6` (exit 0):
* `PE32+ executable (DLL) (GUI) x86-64`, optional header magic `0x020b`.
* Exports: **`duckdb_oracle_init_c_api` only**.
* Imports: `KERNEL32.dll`, `ntdll.dll`, and 10 UCRT API sets `api-ms-win-crt-{convert,environment,
  filesystem,heap,locale,private,runtime,stdio,string,time}-l1-1-0.dll`. All are standard Windows 10+
  system components. There is no libgcc, libstdc++, vcruntime, or oci.dll import, because OCI is loaded with
  `LoadLibrary` at run time.
* Footer: platform `windows_amd64`, duckdb/C API version `v1.5.6`, extension version `v0.1.0`, ABI
  `C_STRUCT`, magic `4`, signature area empty (unsigned).

**I did not run this on real Windows.** Under Wine 9.0, with the official
`duckdb_cli-windows-amd64.zip` v1.5.6, I got the following. These results are hints, not proof.
* Before `LOAD`, there were 0 `duckdb_oracle` rows and 0 `oracle_*` functions. `LOAD` succeeded with `loaded=true` and exit 0.
* With no `oci.dll`, `oracle_client_info()` reported `DPI-1047 ... "Module not found"` and exited with 0.
* With **Windows Instant Client Basic x64 19.26** on `WINEPATH`, `oracle_client_info()` reported
  `found=true, 19.26.0.0.0, Z:\tmp\icwin\instantclient_19_26\oci.dll`. Querying the unreachable DSN gave
  `ORA-12541: TNS:no listener` and exit code 1.

### Check 5: logic tests and unit tests. PASS, with limited scope

* SQLLogicTests are in `test/sql/`: `duckdb_oracle_load.test`, `duckdb_oracle_client_info.test` and `duckdb_oracle_query_errors.test`.
  They run through `duckdb_sqllogictest` (commit `2ac8dbc0`, the same pin as extension-ci-tools) on the
  **stock `duckdb==1.5.6` wheel**, using `--external-extension`. They check:
  * the functions are absent before `require duckdb_oracle`;
  * `loaded=true` and both functions are registered;
  * `oracle_client_info()` has the right shape, reports DPI-1047 when no client is present and a version when one is;
  * NULL dsn and NULL sql are rejected;
  * empty user and empty password are rejected;
  * an unknown named parameter is rejected;
  * an unreachable DSN produces `DPI-1047|ORA-125xx`, and the extension still works afterwards.

  Results: 3/3 pass without a client and 3/3 pass with a client.
  A deliberately wrong expectation was reported as ERROR, which confirms the runner really
  checks results.
* Zig unit tests in `src/convert.zig` (10 tests, `zig build test`) use hand-built
  `dpiDataTypeInfo` and `dpiData` values. They cover:
  * the NUMBER precision/scale mapping, including negative scale, s > p, FLOAT and unconstrained NUMBER;
  * every other type mapping and the unsupported types;
  * DATE/TIMESTAMP to epoch microseconds;
  * TIMESTAMP TZ offset handling, with positive and negative offsets;
  * DECIMAL text parsing, rounding and overflow;
  * int16/int32/hugeint decimal storage;
  * INTERVAL DS/YM;
  * fetch-batch sizing.

  The expected timestamp values were cross-checked against DuckDB's own `epoch_us()`.

## 3. Decisions, deviations from the brief, and defects found

### 3.1 Defects found and fixed

1. **Windows hang on first Oracle call** (found under Wine, then fixed). A Zig-root DLL
   gets Zig's own `_DllMainCRTStartup`, and that entry point does **not** run C static constructors. ODPI-C
   initialises its global `CRITICAL_SECTION` in an `__attribute__((constructor))`
   (`dpiGlobal__initialize`). Because the constructor never ran, the zeroed critical section
   deadlocked inside the first `dpiContext_createWithParams`. Under Wine, `oracle_client_info()` hung
   (exit 124 from `timeout`, and Wine logged `RtlpWaitForCriticalSection ... blocked by 0000`).
   Linux was unaffected because glibc runs `.init_array`. The fix is in `src/duckdb_oracle.zig`:
   `pub const _DllMainCRTStartup = {};` suppresses Zig's entry point so that the MinGW CRT's `crtdll.c`
   entry point is used, and that one runs the constructors. After the fix, `_DllMainCRTStartup` is no longer exported, and the hang
   is gone under Wine. The pre-fix reproduction is in `evidence-history.txt`, section 07. CI runs
   `oracle_client_info()` on windows-latest with a timeout, so a regression would be caught.
2. **File name versus entrypoint.** DuckDB derives the init symbol from the file name.
   `duckdb_oracle-windows_amd64.duckdb_extension` makes it look for `duckdb_oracle-windows_amd64_init_c_api` and fail
   with an IO Error (seen on Linux). The deliverable file names required by the brief therefore
   **must be renamed to `duckdb_oracle.duckdb_extension`** before `LOAD`/`INSTALL`. `test-windows.ps1` copies the file
   under the correct name automatically, and the README documents the rename.

### 3.2 Decisions

* **Base project.** I combined the two templates. The build structure comes from quack-zig: a
  per-platform loop, the footer written by a `Run` step using the official script, and a sqllogictest step.
  The extension logic is written in Zig, as in habedi's template, and calls the C API through the
  `duckdb_ext_api_v1` function-pointer struct. The entrypoint is written in Zig and is equivalent to
  `DUCKDB_EXTENSION_ENTRYPOINT`. Unlike both templates, nothing is downloaded at build time
  (headers, ODPI-C and the footer script are vendored), and `uv` is not required.
* **C API version: v1.5.6.** The brief says to pin v1.5.6, and the footer has to say v1.5.6. For `C_STRUCT`
  extensions, the footer's version field holds the *C API* version. DuckDB accepts the extension
  when that version is ≤ its own. As a result, this build loads on DuckDB **≥ 1.5.6** within 1.x, but not
  on 1.5.5 or older. The code only uses functions that already existed in the v1.2.0 surface. Building with
  `-Dcapi-version=v1.2.0` produces a binary that also loads on 1.2–1.5.5, but I did not test that variant.
* **Windows ABI: `x86_64-windows-gnu`.** The DuckDB boundary is pure C, so no C++ ABI crosses it.
  Zig ships the MinGW CRT and links against UCRT, which yields system-only imports. The footer platform
  is the standard `windows_amd64`. The README has the full rationale.
* **Linux baseline glibc 2.28** (manylinux_2_28, the same baseline as DuckDB's own builds). The highest
  symbol version referenced is GLIBC_2.27.
* **ReleaseSafe by default.** Zig safety checks stay on in the extension code. UBSan is disabled for
  the vendored ODPI-C C code, so benign UB in third-party code cannot trap inside DuckDB.
* **DECIMAL instead of DOUBLE for `NUMBER(p,s)`.** The C API v1.2+ has
  `duckdb_create_decimal_type`, so values are fetched as text and parsed exactly into the scaled
  integer (int16/32/64/128). `NUMBER(19..38,0)` maps to `DECIMAL(p,0)`. Unconstrained `NUMBER` and `FLOAT`
  map to DOUBLE, as the brief specifies. One consequence: Oracle reports expressions such as
  `COUNT(*)` and `level` as unconstrained, so they arrive as DOUBLE unless you `CAST` them in the Oracle SQL.
* **LOBs are fetched inline as LONG.** CLOB/NCLOB/BLOB are defined as `LONG_(N)VARCHAR` / `LONG_RAW`,
  the same approach python-oracledb thick mode uses with `fetch_lobs=False`. This means no LOB locators can
  leak when a scan stops early.
* **`oracle_client_info()` is a table function** (one row, seven columns). Calling it triggers the
  lazy OCI load, which is serialised by a mutex. A failed load is not cached, so you can install the
  client and retry in the same session.
* **Fetch batch.** Each fetch uses array size `duckdb_vector_size()` (2048), and one fetch fills one DuckDB chunk.
  If a single batch would need more than 64 MiB of buffers (for example, many `VARCHAR2(4000 CHAR)` columns),
  fewer rows are fetched per chunk. This adds a memory guard on top of what the brief asked for.
* **Only queries are accepted.** `dpiStmt_getInfo().isQuery` is checked *before* the describe-only execute,
  because OCI executes DDL even in describe-only mode.
* **Credentials.** `user`/`password` fall back to `ORACLE_USER`/`ORACLE_PASSWORD`, and the password buffer is
  zeroed after connect. DuckDB echoes the failing SQL line in error messages, so passing
  `password := '...'` inline will show up in errors and in CLI history. The README recommends the
  environment variable instead.
* **Extra environment variable.** `DUCKDB_ORACLE_CLIENT_LIB_DIR` maps to ODPI-C's `oracleClientLibDir`. It lets you pin the
  64-bit client on a machine that also has a 32-bit client on PATH.

### 3.3 Things in the brief that needed adapting

* The literal deliverable names can't be loaded without renaming (section 3.1, item 2).
* "Exits with code 0" holds for successful runs. For error cases, the DuckDB CLI exits with 1 by design.
  The requirement there is "no crash", and that is what I verified.

## 4. Not verified

* **Real Oracle queries.** Nothing past `dpiConn_create` was tested: describe, define,
  `dpiStmt_fetchRows`, the conversion of real values (NUMBER text, DATE/TIMESTAMP/TZ/LTZ, CLOB/NCLOB/BLOB
  as LONG, RAW, ROWID, INTERVAL, NULLs), multi-batch fetches, early termination with `LIMIT`, and handle cleanup under
  load. The brief said not to run Oracle or Docker here. These are the most likely places for remaining bugs.
* **Real Windows.** I only did static PE inspection plus Wine runs. I never ran the official Windows CLI on Windows.
* **The GitHub Actions workflow has not run.** I checked its YAML syntax only. The `mlugg/setup-zig@v2` action and the
  runner images are assumptions.
* **`test-windows.ps1`.** It parsed without errors and I ran it end to end on **PowerShell 7.6.7 on Linux**,
  using the Linux CLI and extension: with `-SkipOracle` everything passed, and with Instant Client and an
  unreachable DSN the Oracle steps failed as expected while the error check passed. A grep confirmed that the
  password does not appear in any generated file. It has **not** run on Windows PowerShell 5.1, and its
  32-bit `oci.dll` warning path has not been exercised.
* **The 32-bit oci.dll scenario.** ODPI-C has its own detection for this case (`DPI-1047 ... 64-bit`), but I did not test it.
* **The `-Dcapi-version=v1.2.0` variant** and compatibility with DuckDB versions other than 1.5.6.
* **23ai Instant Client.** Only 19.26 was tested, on Linux, and on Windows under Wine.

## 5. Next steps for the owner (Windows host)

1. Copy `duckdb_oracle-windows_amd64.duckdb_extension` and `test-windows.ps1` into one folder.
2. In PowerShell, from that folder:
   ```powershell
   $s = Read-Host 'Oracle password' -AsSecureString
   $env:ORACLE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
   .\test-windows.ps1 -DuckDB C:\path\to\duckdb.exe     # omit -DuckDB to auto-download the official v1.5.6 CLI
   ```
   The script:
   * lists every `oci.dll` in load order and warns if the first one is 32-bit;
   * checks that duckdb-oracle is not built in;
   * loads the extension (copying it as `duckdb_oracle.duckdb_extension`);
   * runs `SELECT * FROM dual`, a type-coverage query with about 22 per-type `ok_*` checks, a
     5000-row multi-batch query, a `LIMIT` early stop, a NULL round-trip and an unreachable-DSN check;
   * prints every exit code in decimal and hex, kills hung runs after a timeout, and ends with a
     PASS/FAIL summary.
3. If the first `oci.dll` is 32-bit, either reorder `PATH` or set
   `$env:DUCKDB_ORACLE_CLIENT_LIB_DIR = 'C:\...\instantclient_19_26'`.
4. Send back the script output. It contains no password. Any `ok_* = false` line points to the exact
   type conversion to fix. The ones I'm least sure about: `ok_tsltz` (session time-zone semantics), `ok_nch`/`ok_ch`
   (padding), and `ok_clob`/`ok_blob` (LOB-as-LONG define).
5. Push the repo to GitHub so the `ci.yml` workflow runs. The `windows-stock-cli` job is the stock-CLI
   test that the old project was missing.
6. Optional: build from source with `zig build` (Zig 0.15.2 and Python 3 only).


---

## 6. v0.2.0: Oracle 23ai / 26ai support

### 6.1 What changed

* **Instant Client.** I installed the newest Instant Client Basic for Linux x64 alongside 19.26.
  Oracle's "latest" permalink (`instantclient-basic-linuxx64.zip`, built 2026-05-28, sha256
  `4c17d54d57db68d7af54009e99e9871a9f068ca93cbf4d81f1a6606f5f28ea05`) served **23.26.2.0.0**.
  That is the client line released alongside Oracle AI Database 26ai, which still uses the 23.x
  numbering. I found no separate "26.x"-numbered Linux Basic zip. www.oracle.com did not resolve from
  this sandbox (only download.oracle.com did), so I could not browse the download page to check.
* **ODPI-C pin kept at v26.0.0.** `git ls-remote` shows it is still the newest tag. It already has
  BOOLEAN, native JSON (`dpiJson_getValue`), VECTOR (FLOAT32/FLOAT64/INT8/BINARY plus sparse vectors via
  `dpiVectorInfo.isSparse`), the `isOson` flag, and 26ai's three-part version handling. An upgrade
  would add nothing. The reasoning is recorded in `third_party/VERSIONS.md`.
* **New type mapping** in `src/convert.zig` and `src/duckdb_oracle.zig`:
  * BOOLEAN maps to BOOLEAN. This mapping already existed and now has explicit tests.
  * Native JSON, and BLOB `IS JSON (FORMAT OSON)`, map to VARCHAR holding JSON text. A small Zig
    serialiser walks the `dpiJsonNode` tree. Numbers stay exact because they are fetched as text.
  * VECTOR maps to a DuckDB LIST, written with the stable C API list functions
    (`duckdb_create_list_type`, `duckdb_list_vector_reserve`, `duckdb_list_vector_set_size`, and child vector data):
    * FLOAT32 and INT8 become `FLOAT[]`;
    * FLOAT64 and the flexible `*` format become `DOUBLE[]`;
    * BINARY becomes `UTINYINT[]` holding the packed bytes;
    * sparse vectors are expanded to dense lists.

  The C API made lists practical, so I did not need the VARCHAR fallback for VECTOR.
* **19c behaviour is unchanged.** None of the new code paths are reachable with 19c column types, and the
  existing mappings and their tests were not modified. The one exception: a plain `BLOB` is still a BLOB,
  and only a BLOB with ODPI-C's `isOson` flag set becomes JSON. 19c has no OSON columns.
* **Tests.** Zig unit tests went from 10 to 15. The new ones use hand-built `dpiDataTypeInfo`,
  `dpiData`, `dpiJsonNode` and `dpiVectorInfo` values:
  * the 23ai type plans, including OSON and plain BLOB;
  * BOOLEAN values;
  * JSON serialisation of an object/array/scalar tree, checked by re-parsing it with `std.json`, plus
    empty containers, control characters, NaN, DATE and negative INTERVAL YM;
  * VECTOR conversion for FLOAT32/FLOAT64/INT8, a flexible column, BINARY, a sparse vector expanded to
    dense, an invalid sparse index, and an empty vector.
* **`test-windows.ps1` section 4** is optional and is skipped unless `ORACLE_DSN_23AI` is set:
  * user comes from `ORACLE_USER_23AI` (default `SYSTEM`);
  * password comes from `ORACLE_PASSWORD_23AI`, falling back to `ORACLE_PASSWORD`; it reaches duckdb.exe
    only through the environment;
  * it runs `dual` / `v$version`, then the 19c type checks against the 23ai server;
  * when the loaded client is 23 or newer, it also runs 7 BOOLEAN/JSON/VECTOR checks and a 3000-row
    VECTOR query that spans two DuckDB chunks;
  * with an older client (for example your 19.26), it skips those checks with a warning.
* **New tool and CI step.** `tools/client-matrix.sh` reruns checks 2–3 for each client directory. A new CI
  step runs it with no client, with 19.26, and with the latest client.

### 6.2 Verified here (v0.2.0 artifacts, fresh clone of tag v0.2.0)

| Check | No client | Instant Client 19.26.0.0.0 | Instant Client 23.26.2.0.0 (latest) |
|---|---|---|---|
| `zig build` (both targets) / `zig build test` | 9/9 steps, exit 0 / **15/15** tests, exit 0 | n/a | n/a |
| Check 2: `tools/stock-cli-test.sh` (not built in, `LOAD` exit 0, `loaded=true`) | PASS | PASS | PASS |
| `oracle_client_info()` | `found=false`, `DPI-1047`, exit 0 | `19.26.0.0.0`, `/opt/oracle/instantclient_19_26/libclntsh.so`, exit 0 | `23.26.2.0.0`, `/opt/oracle/instantclient_23_26/libclntsh.so`, exit 0 |
| Check 3: `oracle_query('127.0.0.1:1/NOPE', ...)` | `DPI-1047 ...`, exit 1 | `ORA-12541: TNS:no listener`, exit 1 | `ORA-12541: Cannot connect. No listener at host 127.0.0.1 port 1.` (plus a `Help:` URL line), exit 1 |
| SQLLogicTests (3 files) | 3/3 SUCCESS | 3/3 SUCCESS | 3/3 SUCCESS |

`tools/client-matrix.sh` exited with 0 overall. Check 4 (`tools/check-pe.sh`) passes on the v0.2.0 Windows DLL:
* PE32+ x86-64;
* the only export is `duckdb_oracle_init_c_api`;
* it imports only KERNEL32, ntdll and the `api-ms-win-crt-*` DLLs;
* its footer reads `windows_amd64` / `v1.5.6` / `C_STRUCT` / `v0.2.0`.

Under Wine 9.0 (a hint only), the v0.2.0 DLL loads with `loaded=true`. Without a client it reports DPI-1047. With the
Windows 19.26 x64 client it reports `19.26.0.0.0` and returns `ORA-12541` for the unreachable DSN.

`test-windows.ps1` section 4, run on pwsh 7.6.7 on Linux against an unreachable `ORACLE_DSN_23AI`:
* it parses and runs;
* it detects the client version: with 23.26 the BOOLEAN/JSON/VECTOR step runs (and fails on connect,
  as expected), and with 19.26 it is skipped with a warning;
* when `ORACLE_DSN_23AI` is unset, the section is skipped;
* the password appears in 0 generated files.

DuckDB parsed every generated SQL statement: all the failures were ORA-12541 binder errors, not parser errors.

The logs are in `evidence-history.txt`, sections 20–25.

### 6.3 Still needs a real 23ai/26ai server (not verified)

* **Every value conversion against real data.**
  * Do `dpiConn_newVar` and `dpiStmt_define` accept `DPI_ORACLE_TYPE_JSON`/`VECTOR` with array fetch?
  * Does `dpiJson_getValue` return the trees the unit tests assume? This includes OSON field order.
    The test script only checks JSON through `json_extract`, so order doesn't matter there.
  * Does `dpiVector_getValue` return the formats and dimensions the tests assume?
  * Do LIST offsets stay correct across chunks? The 3000-row check in the script covers this.
  * Do BOOLEAN values round-trip?
* **TO_VECTOR / BOOLEAN SQL** in the test script's queries. The syntax is from the 23ai docs and was
  not executed. BINARY and sparse vectors are not in the script, because older 23ai Free images lack them.
* **19c client against a 23ai server.** For JSON/VECTOR/BOOLEAN columns I expect a clean bind-time error
  (an ODPI-C/ORA error or duckdb-oracle's "unsupported type" message). I have not seen what actually happens.
* **The 19c queries on a 23ai server** are expected to behave identically. Section 4b of the script checks this.
* **Windows with a 23ai/26ai Instant Client.** Not tested, not even under Wine. Only the 19.26 Windows client was tried under Wine.
* **The new CI step.** Like the rest of the workflow, it has not run on GitHub. It also depends on Oracle's
  permalink still serving a downloadable zip without a login.

### 6.4 Next steps for the owner (23ai/26ai)

1. Start a 23ai/26ai database, for example
   `docker run -d --name ora23 -p 1522:1521 -e ORACLE_PASSWORD=<pw> gvenzl/oracle-free`.
2. Use a 23ai/26ai x64 Instant Client for the run, for example
   `$env:DUCKDB_ORACLE_CLIENT_LIB_DIR = 'C:\oracle\instantclient_23_26'`. Your 19.26 client still works
   for 19c-style columns, but section 4c will be skipped with it.
3. Set the 23ai connection details, typing the password without echo as in section 5:
   ```powershell
   $env:ORACLE_DSN_23AI = 'localhost:1522/FREEPDB1'
   $s = Read-Host '23ai password' -AsSecureString
   $env:ORACLE_PASSWORD_23AI = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
   ```
4. Run `.\test-windows.ps1`. It runs the 19c checks and section 4 in one pass. Send back the summary and any `ok_* = false` lines.


---

## 7. v0.3.0: DuckDB version portability

Everything below comes from the code, the footer bytes and actual runs. The logs are in `evidence-history.txt`, sections 30–35.

### 7.1 Where v1.5.6 was pinned, and what the footer records

Before v0.3.0, v1.5.6 was pinned in these places:

| Place | Before (v0.2.0) | Now (v0.3.0) |
|---|---|---|
| `build.zig` | `const duckdb_version = "v1.5.6"`. This was used for the header path, the default `-Dcapi-version`, the output dir `zig-out/v1.5.6/<platform>`, and the footer step name | `duckdb_headers_version = "v1.5.6"` (headers only) and `default_target_version = "v1.2.0"`. New option `-Dduckdb-version` (`-Dcapi-version` is kept as an alias). Output goes to `zig-out/<platform>/`. Values outside v1.2.0..v1.5.6 are rejected |
| Headers | `third_party/duckdb/v1.5.6/{duckdb.h,duckdb_extension.h}` | unchanged. They are the tested baseline, and they gate every API by the target version |
| C macros | `DUCKDB_EXTENSION_API_VERSION_{MAJOR,MINOR,PATCH}` = 1,5,6 | set from `-Dduckdb-version` (default 1,2,0) |
| `get_api()` request in `duckdb_oracle_init_c_api` | `"v1.5.6"` (build option) | the same build option, default `"v1.2.0"` |
| **Footer** field 3 (`duckdb_version`), with `abi_type=C_STRUCT` | `v1.5.6` | **`v1.2.0`** |
| Footer writer | extension-ci-tools branch v1.5.6 script | unchanged (the footer format is the same for all 1.x versions) |
| CI | `DUCKDB_VERSION: v1.5.6` for the CLI, wheel and paths | `TARGET_CAPI: v1.2.0`, `DUCKDB_BASELINE: v1.5.6` (wheel, baseline CLI). There is a new stock-CLI matrix and a `-Dduckdb-version` sweep |
| Tests | `duckdb_oracle_client_info.test` expected `duckdb_capi_version = 'v1.5.6'` | now checks the pattern `v1.x.y`. `tools/check-pe.sh` defaults to v1.2.0 |
| `test-windows.ps1` | `$DuckDBVersion = 'v1.5.6'` hard-coded | `-DuckDBVersion` parameter, default v1.5.6 |
| Docs | README said "v1.5.6" throughout | README has a new "Supported DuckDB versions" section |

**What the footer records.** For `abi_type=C_STRUCT`, DuckDB v1.5.6 (`ParseExtensionMetaData`) reads
field 3 as `duckdb_capi_version`, not as a DuckDB release. `CheckExtensionMetadata` then accepts the file
when major == 1 and the version is ≤ its own. So the footer records a **minimum C API version**. It was
v1.5.6 before and is v1.2.0 now. A release-exact check applies only to the `CPP` and `C_STRUCT_UNSTABLE` ABI types.

### 7.2 Stable API only: confirmed, nothing to remove

* duckdb-oracle calls 43 DuckDB functions, all through the `duckdb_ext_api_v1` struct, plus `get_api`,
  `get_database` and `set_error` from the `duckdb_extension_access` struct.
* In the vendored header, every one of the 43 is declared in a stable `DUCKDB_API_VERSION_AT_LEAST(x,y,z)` band. The
  newest band used is **(1, 2, 0)**, for `duckdb_is_null_value`. All the others date from 0.2.7–0.10.0. The full table is in `evidence-history.txt` section 31.
* Nothing defines `DUCKDB_EXTENSION_API_VERSION_UNSTABLE` or `DUCKDB_API_ALLOW_UNSTABLE`, so the unstable members are
  not even present in the struct. Because `duck("name")` resolves at compile time with `@field`, any unstable or
  too-new function is a compile error.
* The footer ABI type is `C_STRUCT`, not `C_STRUCT_UNSTABLE`.
* I added a negative control. When `duckdb_unsafe_vector_assign_string_element_len` (a v1.5.6-only function) is added
  to the code, the v1.2.0 build fails with `no field named ... in struct duckdb_ext_api_v1` and the v1.5.6 build
  succeeds. This shows the version gate really is enforced.

There was no unstable usage, so I removed nothing.

### 7.3 Build option

`zig build -Dduckdb-version=vX.Y.Z` sets the minimum DuckDB version. The default is **v1.2.0**, the lowest the code
needs; it is also the first release that has the C Extension API.

A sweep over v1.2.0, v1.3.0, v1.4.0, v1.5.0 and v1.5.6 compiles each one, and each footer carries the
requested version. Asking for v1.1.3 or v1.6.0 is rejected with a clear message. CI repeats this sweep.

### 7.4 Portability proof: one unchanged binary in official CLIs

I loaded a single linux_amd64 file (sha256 `e2d2a0ce…be48`, footer C API v1.2.0) into each official Linux CLI downloaded
from GitHub releases. No Oracle client was on the library path. v1.5.6 is the newest release as of 2026-10-17
(`git ls-remote --tags`).

| DuckDB CLI | CLI platform | Before LOAD (duckdb_oracle rows, oracle_* fns) | `LOAD` + `duckdb_extensions()` | exit | stock-cli-test |
|---|---|---|---|---|---|
| v1.5.6 (newest) | linux_amd64 | 0, 0 | `duckdb_oracle loaded=true installed=false extension_version=v0.3.0 install_mode=NOT_INSTALLED` | 0 | **PASS** |
| v1.5.0 | linux_amd64 | 0, 0 | `duckdb_oracle loaded=true … v0.3.0` | 0 | **PASS** |
| v1.4.5 | linux_amd64 | 0, 0 | `duckdb_oracle loaded=true … v0.3.0` | 0 | **PASS** |
| v1.3.2 | linux_amd64 | 0, 0 | `duckdb_oracle loaded=true … v0.3.0` | 0 | **PASS** |
| v1.2.2 | **linux_amd64_gcc4** | 0, 0 | `Invalid Input Error: ... built for the platform 'linux_amd64', but we can only load extensions built for platform 'linux_amd64_gcc4'` | 0 (*) | FAIL (expected) |
| v1.2.2, unchanged file + `SET allow_extensions_metadata_mismatch=true` | | | `loaded=true`, `oracle_client_info()` works | 0 | — |
| v1.2.2, `linux_amd64_gcc4` build | | | `loaded=true` | 0 | **PASS** |
| v1.2.0 | **linux_amd64_gcc4** | 0, 0 | same platform error | 0 (*) | FAIL (expected) |
| v1.2.0, unchanged file + mismatch override | | | `loaded=true`, `duckdb_capi_version=v1.2.0` | 0 | — |
| v1.2.0, `linux_amd64_gcc4` build | | | `loaded=true` | 0 | **PASS** |
| v1.1.3 (below floor) | — | 0, 0 | `Invalid Input Error: ... built for DuckDB C API version 'v1.2.0', but we can only load extensions built for DuckDB C API ...` (clean rejection, no crash) | 1 | FAIL (expected) |

(*) The v1.2.x CLI returns exit code 0 for `-c` even when a statement fails. That is why
`stock-cli-test.sh` also requires `loaded=true`, and it catches this case.

What this shows:
* The **same unchanged binary** loads and works on v1.3.2, v1.4.5, v1.5.0 and v1.5.6.
* On v1.2.x, the C API part works: `loaded=true` and functions callable once the platform check is overridden.
  The only obstacle is that those official Linux builds call their platform `linux_amd64_gcc4`, so I added
  `-Dplatform=linux_amd64_gcc4`. Its library bytes are verified identical to linux_amd64 (`cmp` with the footer stripped).
* `oracle_client_info()` and the Oracle checks are unaffected. On the v1.5.6 baseline, checks 2–3 still pass with
  no client, with 19.26 and with 23.26, and 3/3 SQLLogicTests pass with each (`evidence-history.txt` section 33).

Windows, Wine only (a hint, not proof): the same v0.3.0 `windows_amd64` DLL loads with `loaded=true` and exit 0
in both the official Windows CLI **v1.5.6** and **v1.2.0**. Both report platform `windows_amd64`, so v1.2.x needs no
special label on Windows. Check 4 (`tools/check-pe.sh`, footer v1.2.0) passes.

### 7.5 CI matrix

`.github/workflows/ci.yml` has a new job, `stock-cli-matrix`, over
`os: [ubuntu-latest, windows-latest]` × `duckdb: [v1.2.0, v1.3.2, v1.4.5, v1.5.6]`. Each cell downloads the official CLI
and runs the stock-CLI load test on the unchanged CI artifacts:
* **Linux** runs `tools/stock-cli-test.sh`. It picks the artifact matching `PRAGMA platform`, which means the gcc4 label on v1.2.x.
* **Windows** runs the brief's `LOAD` command, checks the exit code and `loaded=true`, and runs `test-windows.ps1 -SkipOracle -DuckDBVersion …`.
  On v1.5.6 it also runs under Windows PowerShell 5.1.

**This has not run on GitHub.** I only checked the YAML syntax, and I ran the same commands locally for the Linux cells.

### 7.6 Not verified

* The Windows matrix cells on real Windows. Only Wine was tried, for v1.2.0 and v1.5.6.
* The SQLLogicTests on DuckDB Python wheels other than 1.5.6.
* The exact UTF-8 behaviour of `duckdb_vector_assign_string_element_len` on older releases. The README hedges this.
* Any Oracle data fetch on any DuckDB version. Sections 4 and 6.3 still apply.


---

## 8. v0.4.0: windows_arm64 build and Windows on ARM

The logs are in `evidence-history.txt`, sections 40–45.

### 8.1 The build

* `build.zig` has a new platform, `windows_arm64`, built for `aarch64-windows-gnu`. It is now part of the default
  `zig build` alongside linux_amd64 and windows_amd64. The pure-C ABI argument for MinGW on x64 applies equally to ARM64.
* The same DuckDB versions as before are supported: the default build targets C API v1.2.0, and `-Dduckdb-version`
  works for this platform too.
* The vendored ODPI-C compiled for ARM64 without any changes.
* Fresh clone of tag v0.4.0: `zig build` for all four platforms completed 17/17 steps with exit 0. The unit tests now number 22
  (the 7 new ones cover architecture hints) and all pass.

### 8.2 Inspection, done the same way as windows_amd64

Ubuntu's x86 `objdump` cannot read ARM64 PE files ("file format not recognized"). I therefore added
`tools/pe_inspect.py`, a dependency-free parser for the PE headers, export table and import table. I validated it
against `objdump`: both produce an identical import list for the x64 DLL. `tools/check-pe.sh <file> <capi> <platform>`
now uses it for both architectures.

| Check | windows_amd64 | windows_arm64 |
|---|---|---|
| Machine type | `0x8664` IMAGE_FILE_MACHINE_AMD64 | **`0xaa64` IMAGE_FILE_MACHINE_ARM64** |
| Optional header / DLL flag | PE32+ (`0x20b`), DLL | PE32+ (`0x20b`), DLL |
| Exports | exactly `duckdb_oracle_init_c_api` | exactly `duckdb_oracle_init_c_api` |
| Imports | KERNEL32, ntdll, 10× `api-ms-win-crt-*` | the same 12 system DLLs |
| Footer | `windows_amd64` / `v1.2.0` / `C_STRUCT` / `v0.4.0` | **`windows_arm64`** / `v1.2.0` / `C_STRUCT` / `v0.4.0` |
| `check-pe.sh` | PASS | PASS |

As a negative control, checking the ARM64 file as `windows_amd64` fails with "machine is not 0x8664".

**Platform string.** I wanted to be sure the official DuckDB Windows ARM64 build really reports `windows_arm64`.
`DuckDBPlatform()` in the v1.5.6 source derives the arch from `__aarch64__`, which MSVC does not define. Without an override
it would therefore report `windows_amd64`, unless the build sets `DUCKDB_CUSTOM_PLATFORM`. To settle this, I downloaded the official
`duckdb_cli-windows-arm64.zip` v1.5.6. It contains an ARM64 PE (`0xaa64`) with the literal string `windows_arm64` in it,
and the x64 CLI contains no `windows_amd64` literal. So the release build sets the custom platform to `windows_arm64`,
which matches our footer. This is evidence from the binary; I have not run it. Official Windows ARM64 CLIs also exist for v1.2.0, v1.3.2 and v1.4.5.

**Not verified:** I have not loaded the windows_arm64 DLL into an ARM64 DuckDB. Wine on x86 cannot run ARM64 code, and there is no
ARM64 Windows machine here. The new CI job `windows-arm64`, on the `windows-11-arm` runner, does exactly that, but it has not run.

### 8.3 Oracle Instant Client for Windows ARM64: none found

* I could not view Oracle's download catalogue (`www.oracle.com`): DNS fails in the sandbox, and the web-fetch tool blocks that host.
* I probed `download.oracle.com` directly with HEAD requests:
  * **Controls return 200:** Linux x64, Linux ARM64 (`instantclient-basic-linux-arm64.zip`, `…linux.arm64-23.26.3.0.0.zip`),
    macOS ARM64, Windows x64 (`…windows.x64-23.26.3.0.0.zip`, `…23.26.2.0.0`, `…19.26.0.0.0dbru`) and the Windows
    "latest" permalinks.
  * **Every Windows ARM64 name variant returns 404:** I tried `-arm64`, `.arm64`, `-aarch64`, `.aarch64`, `-arm` and `nt-arm64`, both as
    permalinks and in the versioned 23.26.2 and 23.26.3 directories.
* I read the `oci.dll` inside the Windows "latest" permalink zip over HTTP range requests. Its machine type is `0x8664` (**x64**).
* ODPI-C v26.0.0's own installation guide lists Windows Instant Client only as "64-bit" (winx64) and "32-bit". It
  lists ARM (aarch64) for Linux only.

**Conclusion:** there is no Windows ARM64 Instant Client. This conclusion is evidence-based but indirect, because the
catalogue page itself was unreachable. A native ARM64 process cannot load an x64 `oci.dll`, so **on Windows ARM, use the
x64 DuckDB CLI with the `windows_amd64` extension and the x64 Instant Client, all running under x64 emulation.**
The `windows_arm64` build is still useful for `LOAD` and for a future ARM64 client, but it cannot reach Oracle today.

### 8.4 How the extension explains this

* `oracle_client_info()` has two new columns:
  * `process_arch`: the architecture this binary was compiled for.
  * `host_arch`: the machine's native architecture. On Windows this comes from `IsWow64Process2`, resolved at run time so no
    new import is added, with a `GetNativeSystemInfo` fallback. It reports `arm64` even for an emulated x64 process. On Linux it comes from `uname`.
* When the client is missing on Windows, both `message` and the `oracle_query()` bind error get a `| hint: …` suffix:
  * **Native ARM64 process:** "Windows ARM64: Oracle publishes no Windows ARM64 Instant Client, and a native ARM64 process
    cannot load an x64 oci.dll. Use the x64 DuckDB CLI + the windows_amd64 duckdb-oracle extension + the x64 Instant Client instead
    (they run under Windows x64 emulation)."
  * **x64 process on an ARM64 host:** a hint to install the x64 Instant Client and the x64 VC++ redistributable. On success the
    message reads `OK (x64 process running under emulation on an arm64 host)`.
  * **First `oci.dll` on the search path has another architecture:** "The first oci.dll on the search path is <arch>, but
    this DuckDB process is <arch>: the architectures must match." The architecture comes from `SearchPathW` plus its PE header.
* The hint logic is a pure function (`src/arch.zig`) with 6 unit tests, which cover the ARM64 and emulated cases and a small buffer.
* **Verified under Wine (x64, a hint only):**
  * no `oci.dll`: no hint, because process and host are both x64;
  * the windows_arm64 duckdb-oracle DLL planted as the first `oci.dll`: ODPI-C reports `...oci.dll is not the correct architecture`,
    and duckdb-oracle adds "The first oci.dll on the search path is arm64, but this DuckDB process is x64". This shows up both in
    `oracle_client_info()` and in the `oracle_query()` error (exit 1, no crash);
  * the real x64 19.26 client: `OK`.
* **Not verified:** the ARM64-process hint and the emulated-on-ARM64 detection running on real ARM64 hardware.
  These are covered only by unit tests.

### 8.5 test-windows.ps1

* **Host architecture** is read from the registry (`HKLM\...\Session Manager\Environment\PROCESSOR_ARCHITECTURE`), which
  is not virtualised for emulated processes. The script falls back to environment variables, then to .NET.
* **Architectures of duckdb.exe, the extension and the first `oci.dll`** are read from their PE headers. The script prints a host / duckdb.exe / extension / oci.dll table and adds an
  `architecture` result. It warns when:
  * the extension doesn't match duckdb.exe ("LOAD will fail; use duckdb_oracle-windows_<arch>");
  * the first `oci.dll` doesn't match duckdb.exe (this replaces the old check that only caught 32-bit);
  * duckdb.exe is native ARM64 (no ARM64 Instant Client exists).

  On an ARM64 host it prints the recommended setup. An x64 duckdb.exe on an ARM64 host is reported as the supported setup.
* **New parameter `-DuckDBArch x64|arm64`** (default x64, also on ARM64 hosts) chooses which official CLI zip is downloaded. When
  `-Extension` isn't given, the extension matching duckdb.exe is picked.
* **Verified:** it parses with 0 errors and ran on pwsh 7.6.7 on Linux. A matching setup passes. The windows_arm64 extension with an x64 `oci.dll`
  produced both mismatch warnings. **Not verified:** a run on real Windows x64 or ARM64.

### 8.6 CI

* The build job now builds and checks `windows_arm64` (footer, `check-pe.sh`).
* The new job `windows-arm64` runs on `windows-11-arm` with `cli: [arm64, x64]`. Each cell runs
  `test-windows.ps1 -SkipOracle -DuckDBArch …` and prints `oracle_client_info()` (process_arch, host_arch, hint).
* None of this has run. The `windows-11-arm` runner label is an assumption: it is GitHub's hosted Windows ARM64 runner for public repos.

### 8.7 Regression

The v0.4.0 Linux binary was rerun against the earlier checks:
* Checks 2–3 with no client, with 19.26 and with 23.26: all pass.
* SQLLogicTests: 3/3 with each client.
* Stock-CLI load test: passes on v1.5.6, v1.4.5 and v1.3.2 (linux_amd64), and on v1.2.0 (linux_amd64_gcc4).

The windows_amd64 DLL still passes `check-pe.sh`, and under Wine it still loads and works with the 19.26 client.


---

## 9. v0.5.0: one source tree for Zig 0.15.2 .. 0.17.x

The logs are in `evidence-history.txt`, sections 50–53. Zig 0.17.0 (released 2026-10-01, sha256 `1cbe9df9…2026`) is the newest
stable release according to `ziglang.org/download/index.json`.

### 9.1 Breaking changes, collected from compiler errors

I built the v0.4.0 tree with Zig 0.17.0 and fixed the errors wave by wave. Zig stops at the build script before it
compiles `src/`, and a later error in the same function stays hidden until the earlier one is fixed. To confirm the
two hidden ones, I reverted a single shim at a time in v0.5.0. The raw errors are in `evidence-history.txt` section 52.

| # | Compiler error under 0.17.0 | Change | Fix | Where |
|---|---|---|---|---|
| 1 | `no field named 'ReleaseSafe' in enum 'lang.Optimize'` | 0.17.0: `std.builtin.OptimizeMode` is now an alias of `std.lang.Optimize`, with fields `debug/safe/fast/small`. The PascalCase names remain only as deprecated decls | `compat.optimizeMode()` picks the field via `@hasField(OptimizeMode, "safe")`. `-Doptimize=` accepts `ReleaseSafe` and `safe` on every version | `build_compat.zig` |
| 2 | `member function expected 1 argument(s), found 0` (`captureStdOut`) | 0.17.0: `Step.Run.captureStdOut(options)` | detected by parameter count, using `@typeInfo` | `build_compat.zig` |
| 3 | `no field named 'build_root' in struct 'Build'` | 0.17.0: `Build.build_root: Cache.Directory` was replaced by `Build.root: Cache.Path` | `@hasField(std.Build, "build_root")` | `build_compat.zig` |
| 4 | (hidden) `union 'process.SpawnOptions.StdIo' has no member named 'Ignore'` | 0.17.0: the stdio argument of `runAllowFail` became a tagged union with lowercase tags | the parameter type is read via `@typeInfo`, then `@hasField(T, "ignore")` | `build_compat.zig` |
| 5 | (hidden, inside shim 2/4) `no field named 'params' in struct 'lang.Type.Fn'` | 0.17.0: `Type.Fn.params` was replaced by `param_types` and `param_attrs` | `fnParamCount` / `fnParamType` with `@hasField` | `build_compat.zig` |
| 6 | `invalid builtin function: '@cImport'` | 0.17.0: `@cImport` was removed | **Not a shim.** The headers are now translated by the build system: `src/c_headers.h` goes through `b.addTranslateC`, which exists with the same API in 0.15.2 and 0.17.0, and becomes the module `c_headers`. Translation runs per target, so the Windows `long` size and similar are correct | `build.zig`, `src/c.zig` |
| 7 | `'mem' has no member named 'trimRight'` | `trimRight` was already a deprecated alias in 0.15 and was removed in 0.17 | **Not a shim.** `std.mem.trimEnd` exists in both versions | `src/convert.zig`, `src/oracle.zig` |
| 8 | `'Thread' has no member named 'Mutex'` | 0.17.0: `std.Thread.Mutex` was removed. `std.Io.Mutex.lock(io)` needs an `Io`, and a loaded DLL has none | `compat.Mutex` is `std.Thread.Mutex` when `@hasDecl`, otherwise a small spin lock. It guards only the one-time ODPI-C context creation | `src/compat.zig` |
| 9 | `'fmt' has no member named 'bufPrintZ'` | 0.17.0: replaced by `bufPrintSentinel(…, 0)` | `@hasDecl(std.fmt, "bufPrintZ")` | `src/compat.zig` |
| 10 | `'process' has no member named 'getEnvVarOwned'` | 0.16.0: removed. The environment now comes from `std.process.Environ`, which is passed to `main` and is not available inside a shared library | `compat.getEnvOwned()` calls a C helper in `src/platform.c` (`GetEnvironmentVariableW` and UTF-8 on Windows, `getenv` elsewhere). It behaves the same on all versions and has a unit test against the real environment | `src/compat.zig`, `src/platform.c` |
| 11 | `no field or member function named 'dupeZ' in 'mem.Allocator'` | 0.17.0: replaced by `dupeSentinel(T, m, 0)` | `@hasDecl(std.mem.Allocator, "dupeZ")` | `src/compat.zig` |

Two more points:
* **Windows DLL entry point.** Since v0.1.0, `duckdb_oracle.zig` declares `_DllMainCRTStartup` to stop Zig 0.15 from exporting
  its own DLL entry point. That keeps the MinGW CRT entry point, which runs ODPI-C's constructor (the deadlock fix
  from section 3.1). In Zig 0.17.0's `std/start.zig`, no entry point is exported when libc is linked, so the
  declaration has no effect there. It has to stay in the root module, and both files document it.
  Under Wine, the DLL built with 0.17.0 loads, and `oracle_client_info()` returns with no hang, both without a client
  and with the 19.26 client.
* **Detection method.** All shims use `@hasDecl`, `@hasField` or `@typeInfo`. None needed `builtin.zig_version`.
  Each shim names the version that introduced the change. Outside `build_compat.zig` and `src/compat.zig`, the code calls only
  APIs that are identical in 0.15.2 and 0.17.0. Some of those are deprecated in 0.17 but still present, for example
  `std.fmt.bufPrint` (0.17 suggests `mem.print`). They will need shims once a future Zig removes them.

### 9.2 Version pins

* `build.zig.zon`: `minimum_zig_version = "0.15.2"`. Zig 0.17.0 accepts the file unchanged.
* `mise.toml` is new and pins `zig = "0.15.2"`. That is the single default toolchain, and the released artifacts are built with it.
* The README has a new "Zig versions" section with the supported range, a summary of the shims, and how to build with another Zig.
* The CI `build` job and `windows-native-build` job now run over the matrix `zig: ["0.15.2", "0.17.0"]`. For each Zig version, the build
  job runs build, unit tests, the stock-DuckDB Linux load test, the client matrix and the SQLLogicTests, and uploads
  `duckdb-oracle-extensions-zig-<ver>`. `stock-cli-matrix` then loads **each Zig version's artifacts** into DuckDB v1.2.0, v1.3.2, v1.4.5 and v1.5.6
  on Ubuntu and Windows, which makes 16 cells. **Not run on GitHub;** I only validated the YAML.

### 9.3 Verification, run for real in fresh clones of tag v0.5.0 with empty Zig caches

| Check | Zig 0.15.2 | Zig 0.17.0 |
|---|---|---|
| `zig build`, all four platforms | 21/21 steps, exit 0 | 21/21 steps, exit 0 |
| `zig build test` | **25/25 passed** | **25/25 passed** |
| `-Dduckdb-version` v1.2.0 / v1.4.0 / v1.5.6 | each compiles, footer matches | each compiles, footer matches |
| Footers (linux_amd64, linux_amd64_gcc4) | OK | OK |
| `check-pe.sh` windows_amd64 / windows_arm64 | PASS / PASS | PASS / PASS |
| Stock-CLI load test, DuckDB v1.5.6 / v1.4.5 / v1.3.2 / v1.2.0 (gcc4) | PASS ×4, exit 0 | PASS ×4, exit 0 |
| `duckdb_extensions()` on v1.5.6 | `duckdb_oracle,true,false,v0.5.0,NOT_INSTALLED` | `duckdb_oracle,true,false,v0.5.0,NOT_INSTALLED` |
| Client matrix (none / 19.26 / 23.26), checks 2–3 | exit 0: DPI-1047; ORA-12541; ORA-12541 | exit 0: identical |
| SQLLogicTests per client | 3/3, 3/3, 3/3 | 3/3, 3/3, 3/3 |
| Wine (hint only): windows_amd64 in the Windows CLI v1.5.6, no client / with 19.26 | loaded=true, DPI-1047, exit 0 / `19.26.0.0.0`, `OK`, exit 0 | the same, no hang |

The unit test count grew from 22 to 25: the compat shims, plus `getEnvOwned` against the real C helper.

**Zig 0.16.0**, the middle of the range, was also tried: build 16/16, tests 25/25, and the stock-CLI load test on v1.5.6 passes
(`evidence-history.txt` section 53).

### 9.4 Binaries from each Zig version

The 0.15.2 and 0.17.0 builds are not byte-identical, as expected with different compilers. Both pass every check above,
and both load into the stock CLIs.

| Artifact | Zig 0.15.2 (shipped) | Zig 0.17.0 |
|---|---|---|
| linux_amd64 | `7e895450…8339` | `cf3bd98b…5eda` |
| linux_amd64_gcc4 | `013859a1…04a9` | `4077c372…7ec3` |
| windows_amd64 | `73e5f7d8…e3cf` | `37cf2ad9…d26ff` |
| windows_arm64 | `873ffada…666d` | `ed56e86c…0b46` |

### 9.5 Not verified

* The CI matrix on GitHub, including Windows builds made with Zig 0.17.0 on a Windows host.
* Zig 0.17.x patch releases after 0.17.0, because none exist yet.
* Real Windows (as before, only Wine) and any Oracle data fetch (sections 4 and 6.3 still apply).


---

## 10. v0.6.0: rename to duckdb-oracle

The logs are in `evidence.txt`, sections 60–64.

### 10.1 What changed

The rename is a single commit (`9d8587b`, tagged v0.6.0) touching 19 files.

**Hyphenated name `duckdb-oracle`**, used where hyphens are valid:
* repo directory: `/work/duckdb-oracle`
* tarball: `duckdb-oracle-src.tar.gz`
* README/REPORT titles and prose
* CI workflow name (`duckdb-oracle CI`)
* CI artifact names (`duckdb-oracle-extensions-zig-<ver>`)
* the `test-windows.ps1` work directory (`%TEMP%\duckdb-oracle-smoke`) and temporary log names

**Identifier name `duckdb_oracle`**, used where an identifier is required:
* DuckDB extension name (`DUCKDB_EXTENSION_NAME`, `require duckdb_oracle`, `LOAD duckdb_oracle`)
* exported init symbol **`duckdb_oracle_init_c_api`**
* `--extension-name` passed to the footer script
* build artifact/module name and `build.zig.zon` `.name`
* root source `src/duckdb_oracle.zig`
* C helpers `duckdb_oracle_*`
* SQLLogicTest files `test/sql/duckdb_oracle_*.test`
* output file `duckdb_oracle.duckdb_extension`
* release names `duckdb_oracle-<platform>.duckdb_extension`

**Unchanged:** `oracle_query`, `oracle_client_info` and their arguments.

**Changes forced by the naming rule** (no other behaviour changed):

| Item | Before | After |
|---|---|---|
| `oracle_client_info()` version column | (former name)`_version` | `duckdb_oracle_version` |
| Client-directory override env var | (former name, upper case)`_ORACLE_CLIENT_LIB_DIR` | `DUCKDB_ORACLE_CLIENT_LIB_DIR` |
| Error message prefix | (former name)`: …` | `duckdb_oracle: …` |
| ODPI-C driver name reported to Oracle | (former name) | `duckdb_oracle` |
| `build.zig.zon` fingerprint | `0x925f0a58e145324a` | `0x9c11bb634dbc08c4` (Zig requires a new fingerprint when `.name` changes) |

**No behaviour change.** I checked this with a normalised diff: every non-doc file was compared with the old/new
names masked out. Only two differences remain, both intended: the CI workflow name, and the zon fingerprint.

### 10.2 Verification (fresh clones of tag v0.6.0, empty Zig caches, both supported Zig versions)

| Check | Zig 0.15.2 | Zig 0.17.0 |
|---|---|---|
| `zig build`, all four platforms | 21/21, exit 0 | 21/21, exit 0 |
| `zig build test` | 25/25 | 25/25 |
| `-Dduckdb-version` v1.2.0 / v1.4.0 / v1.5.6 | footers match | footers match |
| Stock-CLI load test, DuckDB v1.5.6 / v1.4.5 / v1.3.2 / v1.2.0 (gcc4) | PASS ×4 | PASS ×4 |
| `LOAD '…/duckdb_oracle.duckdb_extension'` in v1.5.6, then `duckdb_extensions()` | `duckdb_oracle  true  false  v0.6.0`, rows matching the old name: 0, exit 0 | the same |
| Client matrix (none / 19.26 / 23.26) | exit 0 (DPI-1047 / ORA-12541 / ORA-12541) | the same |
| SQLLogicTests (renamed files, `require duckdb_oracle`) per client | 3/3 ×3 | 3/3 ×3 |
| Exported symbols | Linux: `duckdb_oracle_init_c_api` only. windows_amd64 (`0x8664`) and windows_arm64 (`0xaa64`): `['duckdb_oracle_init_c_api']` | the same |
| `check-pe.sh` windows_amd64 / windows_arm64 (machine, exports, imports, footer) | PASS / PASS | PASS / PASS |
| Wine (a hint only): windows_amd64 in the Windows CLI v1.5.6, no client / with 19.26 | `loaded=true` / `19.26.0.0.0`, `OK` | the same |
| Old-name strings inside the eight binaries (`grep -a -c -i`) | 0 | 0 |

Additional checks:
* `test-windows.ps1 -SkipOracle` on pwsh 7.6.7 on Linux copies a release-named file to `duckdb_oracle.duckdb_extension`,
  loads it with `duckdb_oracle loaded=true`, and passes every step.
* **Footer extension name.** The DuckDB metadata footer has **no** extension-name field. The fields are magic,
  platform, C API version, extension version and ABI type. `append_extension_metadata.py` uses `--extension-name` only
  to name its default output file, and DuckDB takes the extension name from the **file name**. Our build passes
  `--extension-name duckdb_oracle` and writes `duckdb_oracle.duckdb_extension`. The footers read back as `windows_amd64`
  or `windows_arm64`, `v1.2.0`, `v0.6.0`, `C_STRUCT`.
* **Release file names still need renaming before loading** (superseded by section 11, which ships zips instead). This is unchanged DuckDB behaviour, now with the new name:
  loading `duckdb_oracle-linux_amd64.duckdb_extension` directly fails with
  `did not contain function "duckdb_oracle-linux_amd64_init_c_api"`. Rename the file to `duckdb_oracle.duckdb_extension` first.

Hashes of the Zig 0.17.0 builds:

| Artifact | SHA-256 |
|---|---|
| linux_amd64 | `2210061d…0aaf` |
| linux_amd64_gcc4 | `02c2b970…5163` |
| windows_amd64 | `83ff9653…861a` |
| windows_arm64 | `ca72acf0…13a9` |

### 10.3 Leftover-name check

After deleting the stale, git-ignored `zig-out/` and `.zig-cache/` from before the rename, I ran
`grep -rniI` over the working tree, excluding `.git`. It finds the old name **once**, in the README line
"formerly …". No file or directory name contains it.

Places that still contain the old name, deliberately:
* **Git history.** Two commits and the tags v0.1.0–v0.5.0 mention it. History was not rewritten.
* **`evidence-history.txt`** in the outputs. These are the verbatim raw logs of the pre-rename runs, and editing them would misrepresent what was run.

### 10.4 Owner action

* Rename `DUCKDB_ORACLE_CLIENT_LIB_DIR` in any scripts that set the old variable.
* Use `LOAD duckdb_oracle` or the new file name. If you previously ran `INSTALL` under the old name, the old
  extension stays installed under that name until you remove it from `~/.duckdb/extensions/<version>/<platform>/`.


---

## 11. v0.6.1: ship each platform as a zip containing duckdb_oracle.duckdb_extension

The logs are in `evidence.txt`, sections 70–71.

### 11.1 Problem and fix

DuckDB derives the extension name, and the init symbol it resolves, `<name>_init_c_api`, from the **file name**.
Shipping `duckdb_oracle-<platform>.duckdb_extension` meant every user had to rename the file. Loading it as shipped
failed with `did not contain function "duckdb_oracle-<platform>_init_c_api"`. Earlier, `test-windows.ps1`
silently copied the file to the right name, so the tooling hid the problem.

The fix:
* **Packaging.** `zig build` now also writes `zig-out/dist/duckdb_oracle-<platform>.zip`, using the new `tools/package.py`, which runs
  as a build step. Each zip contains exactly one entry, `duckdb_oracle.duckdb_extension`, with nothing else and no directory.
  The packager refuses any other inner name and checks its own output. The zips are deterministic (fixed
  timestamp and permissions), and rebuilding from scratch gives byte-identical zips.
* **Load tests use the exact shipped file.** This covers `tools/stock-cli-test.sh`, `tools/client-matrix.sh` (through the new
  `tools/shipped-ext.sh`) and `test-windows.ps1`:
  * They take the **zip** and extract it unchanged into a fresh directory.
  * They `LOAD` the extracted `duckdb_oracle.duckdb_extension`.
  * **They never rename anything.** A zip whose only entry is not `duckdb_oracle.duckdb_extension` fails, and so does a
    loose file with any other name. `test-windows.ps1` no longer copies or renames; its default input is
    `duckdb_oracle-windows_<arch>.zip` next to the script.
* **CI.**
  * The load-test steps use the zips. This covers the build job, the Linux and Windows stock-CLI matrix cells, the
    Windows ARM64 job and the native Windows build.
  * The Windows cells unpack the zip and assert that it contains exactly `duckdb_oracle.duckdb_extension`.
  * A new **negative-control** step requires `stock-cli-test.sh` to reject a platform-suffixed copy. It also requires stock DuckDB
    to fail on that copy with `duckdb_oracle-linux_amd64_init_c_api`. This guards against the bug coming back.
* **README.** A new "Distribution: one zip per platform" section lists the zips. The Windows walkthrough now says "unzip,
  don't rename", and the troubleshooting and limitations entries are updated.

Behaviour of the extension itself is unchanged. The `.duckdb_extension` bytes inside the zips are identical to the
built files.

### 11.2 Verification: fresh clones of v0.6.1, run under Zig 0.15.2 and again under Zig 0.17.0

The two runs produced identical output, apart from hashes and temp paths.

| Check | Result (both Zig versions) |
|---|---|
| Build (four platforms plus four zips) / unit tests | 29/29 steps / 25/25 |
| Zip contents | each of the four zips has `entries = ['duckdb_oracle.duckdb_extension']`, and the inner bytes equal the built file |
| Deterministic packaging | after deleting zig-out and the cache and rebuilding, the zips are byte-identical |
| `stock-cli-test.sh <zip>`: stock DuckDB v1.5.6, v1.4.5, v1.3.2 (`…linux_amd64.zip`) and v1.2.0 (`…linux_amd64_gcc4.zip`, chosen by `PRAGMA platform`) | **PASS ×4**, exit 0, loading `<tmp>/duckdb_oracle.duckdb_extension` |
| `LOAD` of the extracted file, then `duckdb_extensions()` (v1.5.6) | `duckdb_oracle,true,v0.6.1`, exit 0 |
| Client matrix from the zip (no client / 19.26 / 23.26) | exit 0 |
| SQLLogicTests | 3/3 |
| Windows zips: extract, then `check-pe.sh` | windows_amd64 and windows_arm64: PASS, exports `['duckdb_oracle_init_c_api']` |
| `test-windows.ps1 -Extension <zip>` (pwsh 7.6.7 on Linux) | `package PASS`, `LOAD + oracle_client_info PASS`, `loaded=true PASS`, exit 0 |
| Wine (a hint only): Windows CLI v1.5.6 with `LOAD 'duckdb_oracle.duckdb_extension'` from the unzipped windows_amd64 zip | `duckdb_oracle,true,v0.6.1`, exit 0 |

**Negative controls.** Each must fail, and each did:
* `stock-cli-test.sh` given `duckdb_oracle-linux_amd64.duckdb_extension` → exit 1, with "is not named duckdb_oracle.duckdb_extension; DuckDB would look for 'duckdb_oracle-linux_amd64_init_c_api'".
* `stock-cli-test.sh` given a zip whose entry is `duckdb_oracle-linux_amd64.duckdb_extension` → exit 1, with "must contain exactly [duckdb_oracle.duckdb_extension]".
* Stock DuckDB `LOAD` of the misnamed file → `did not contain function "duckdb_oracle-linux_amd64_init_c_api"`. This is the original bug, reproduced.
* `test-windows.ps1` given the misnamed file → exit 1.

The Zig 0.17.0 zips differ in bytes, because the compiler output differs. Their SHA-256 prefixes are linux_amd64 `ef4dcd25…`,
linux_amd64_gcc4 `b099c949…`, windows_amd64 `6214a111…` and windows_arm64 `247b0128…`.

**Not verified:** the CI changes, including the negative-control step, have not run on GitHub. `Expand-Archive` and
`System.IO.Compression` in `test-windows.ps1` have run only on pwsh on Linux, not on Windows PowerShell 5.1.
