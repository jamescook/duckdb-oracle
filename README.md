# duckdb-oracle

duckdb-oracle is an unofficial [DuckDB](https://duckdb.org) extension that lets you query an Oracle database with
`oracle_query()` and use the result like any other DuckDB table. It runs on Windows (the main target) and Linux; macOS
(Apple Silicon) can be built from source but is untested. It needs Oracle's free Instant Client, and because it is unofficial
it is unsigned, so DuckDB must be started with `-unsigned`.

## Quick start (Windows)

You need 64-bit Windows 10 or 11, and the address, user name and password of an Oracle database.

1. **Download `duckdb_oracle-windows_amd64.zip`** from the [Releases page](https://github.com/jamescook/duckdb-oracle/releases).
   *No release has been published yet. Until there is one, build the zip yourself (see [Building from source](#building-from-source));
   it ends up in `zig-out/dist/`.*
2. **Install the [Microsoft Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe)** if you don't have it. Instant Client needs it.
3. **Put DuckDB, the extension and Instant Client in one folder** (PowerShell; adjust the Downloads path if needed):
   ```powershell
   $ProgressPreference = 'SilentlyContinue'
   mkdir $HOME\duckdb-oracle; cd $HOME\duckdb-oracle
   Invoke-WebRequest https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-windows-amd64.zip -OutFile duckdb.zip
   Invoke-WebRequest https://download.oracle.com/otn_software/nt/instantclient/instantclient-basic-windows.zip -OutFile instantclient.zip
   Expand-Archive duckdb.zip -DestinationPath .
   Expand-Archive instantclient.zip -DestinationPath .
   Expand-Archive "$HOME\Downloads\duckdb_oracle-windows_amd64.zip" -DestinationPath .
   ```
4. **Put Instant Client on `PATH`** (this window only):
   ```powershell
   $env:PATH = "$((Get-ChildItem instantclient_* -Directory | Select-Object -First 1).FullName);$env:PATH"
   ```
5. **Set your Oracle login** (this window only). The password is typed hidden and never appears in SQL:
   ```powershell
   $env:ORACLE_USER = 'YOUR_ORACLE_USER'
   $env:ORACLE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR((Read-Host 'Oracle password' -AsSecureString)))
   ```
6. **Start DuckDB in this same window**, with unsigned extensions allowed: `.\duckdb.exe -unsigned`
7. **Load the extension and run a query.** Replace `dbhost:1521/ORCLPDB1` with `host:port/service_name` of your database:
   ```sql
   LOAD './duckdb_oracle.duckdb_extension';
   SELECT client_library_found, client_version FROM oracle_client_info();   -- should say true
   SELECT * FROM oracle_query('dbhost:1521/ORCLPDB1', 'SELECT USER AS who, SYSDATE AS now FROM dual');
   ```

To skip the `LOAD` path next time, install it once with `INSTALL './duckdb_oracle.duckdb_extension';`; after that
`LOAD duckdb_oracle;` works in every `-unsigned` session. On a Windows ARM PC use these same x64 files
([details](docs/COMPATIBILITY.md#windows-on-arm)).

## Other platforms

**Linux (x86-64).** Download `duckdb_oracle-linux_amd64.zip` (for DuckDB 1.2.x use `duckdb_oracle-linux_amd64_gcc4.zip`), then:
```sh
mkdir -p ~/duckdb-oracle && cd ~/duckdb-oracle
curl -LO https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip
curl -LO https://download.oracle.com/otn_software/linux/instantclient/instantclient-basic-linuxx64.zip
unzip duckdb_cli-linux-amd64.zip && unzip -q instantclient-basic-linuxx64.zip
unzip ~/Downloads/duckdb_oracle-linux_amd64.zip
export LD_LIBRARY_PATH=$(echo $PWD/instantclient_*)
export ORACLE_USER=YOUR_ORACLE_USER; read -rs -p 'Oracle password: ' ORACLE_PASSWORD; export ORACLE_PASSWORD
./duckdb -unsigned        # (bash) then LOAD './duckdb_oracle.duckdb_extension'; and query as above
```
Instant Client needs the `libaio` library: `sudo apt install libaio1t64` on Ubuntu 24.04 and Debian 13 (older releases:
`libaio1`; Fedora/RHEL: `sudo dnf install libaio`). If it then still complains about `libaio.so.1`, run
`sudo ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1`.

**macOS (Apple Silicon), untested.** There is no download. Build the extension (`zig build -Dplatform=osx_arm64`, see
[Building from source](#building-from-source)), install Oracle's Instant Client for macOS ARM64
([DMG](https://download.oracle.com/otn_software/mac/instantclient/instantclient-basic-macos-arm64.dmg)), point
`DYLD_LIBRARY_PATH` at its folder, and start `duckdb -unsigned`. It builds, but it has never been loaded on a Mac.

## Usage

`oracle_query(dsn, sql)` runs a query **in Oracle** (so write the SQL in Oracle's dialect) and returns its rows. `dsn` is
`host:port/service_name`, or a TNS alias from your `tnsnames.ora`. Your login comes from `ORACLE_USER` and `ORACLE_PASSWORD`.

```sql
-- Query Oracle directly
SELECT employee_id, last_name, salary
FROM oracle_query('dbhost:1521/ORCLPDB1',
                  'SELECT employee_id, last_name, salary FROM hr.employees WHERE department_id = 50');

-- Keep a local copy, or export it
CREATE TABLE employees AS SELECT * FROM oracle_query('dbhost:1521/ORCLPDB1', 'SELECT * FROM hr.employees');
COPY employees TO 'employees.parquet';

-- Join Oracle data with a local file. Do the filtering and counting inside the Oracle SQL.
SELECT d.department_name, c.headcount
FROM oracle_query('dbhost:1521/ORCLPDB1',
       'SELECT department_id, CAST(COUNT(*) AS NUMBER(18,0)) AS headcount FROM hr.employees GROUP BY department_id') AS c
JOIN 'departments.csv' AS d USING (department_id);
```

Good to know: Oracle column names come back in upper case; DuckDB doesn't mind. `COUNT(*)`, sums and other unconstrained numbers arrive
as `DOUBLE` unless you `CAST` them as above. `oracle_client_info()` is the first thing to run when something is wrong: it reports whether
Instant Client was found, which version and from where, and a plain-language message if not.

Options (a different user, a wallet instead of a password, timeouts, ...) are `oracle_query(..., user := 'SCOTT', timeout := 3600)`.
All of them, and the result columns of `oracle_client_info()`, are in the [reference](docs/REFERENCE.md). Type conversions are in
[docs/TYPES.md](docs/TYPES.md).

## Troubleshooting

| You see | Fix |
|---|---|
| `did not contain function "duckdb_oracle-windows_amd64_init_c_api"` (platform name varies) | The file was renamed. It must be called exactly `duckdb_oracle.duckdb_extension`, as in the zip. |
| `... signature is either missing or invalid and unsigned extensions are disabled` | Start DuckDB with `duckdb -unsigned`. |
| `cannot open shared object file: No such file or directory` on `LOAD` (Linux) | Give a path: `LOAD './duckdb_oracle.duckdb_extension';`. |
| `DPI-1047: Cannot locate a 64-bit Oracle Client library` | Instant Client isn't found. Windows: redo step 4, or set `$env:DUCKDB_ORACLE_CLIENT_LIB_DIR` to its folder. Linux: set `LD_LIBRARY_PATH`. If the text says `oci.dll is x86`, you have the 32-bit client; get the x64 one. `SELECT message FROM oracle_client_info();` lists what was searched. |
| `libaio.so.1: cannot open shared object file` (Linux) | Install `libaio`, see [Other platforms](#other-platforms). |
| `DPI-1072 ... oci.dll was loaded from ...`, or `error 126` | Unzip the **whole** Instant Client folder and keep its files together; install the Visual C++ Redistributable (step 2). |
| `no user given` / `no password given` | Set `ORACLE_USER` and `ORACLE_PASSWORD` in the same window that starts DuckDB. |
| `Invalid named parameter "password"` | There is no password argument (DuckDB would print it in errors). Use `ORACLE_PASSWORD`. |
| `ORA-12541`, `ORA-12514`, `ORA-12154`, `ORA-12262` | Oracle can't be reached or found: check host, port, `service_name` and any VPN/firewall; for an alias, `TNS_ADMIN`. |
| `ORA-01017` | Wrong user name or password. |
| `ORA-12170` or `DPI-1067` | A timeout was hit. Add `connect_timeout := 60` (seconds to connect) or `timeout := 3600` (seconds per Oracle call; default 600). |
| `NUMBER value ... cannot be represented exactly as DOUBLE` | Use `CAST(... AS NUMBER(38,0))` in the Oracle SQL, or add `unconstrained_number := 'varchar'`. |

More messages: [docs/REFERENCE.md](docs/REFERENCE.md#errors).

## Limitations

* **Read-only.** Only `SELECT` and `WITH` queries run: no writes, DDL, PL/SQL or `SELECT ... FOR UPDATE`.
* **No `ATTACH` and no pushdown.** Every query names its database and SQL, and all selected columns are fetched, so filter inside the Oracle SQL.
* **Unsigned**, so it can't be installed with `INSTALL ... FROM community`; you must start DuckDB with `-unsigned`.
* **Needs the 64-bit Oracle Instant Client** to match your DuckDB. Oracle has no Windows ARM64 client; see [compatibility](docs/COMPATIBILITY.md).
* **One Oracle session per query, read by one thread.** Ctrl+C can't cancel a running Oracle call; connect and call timeouts (30 s / 600 s by default) end hangs.
* **Early software.** Oracle 19c is the main target, but the tests against a live Oracle server run only on demand, on the maintainer's own 19c database. Please report problems.

The full list is in [docs/REFERENCE.md](docs/REFERENCE.md#known-limitations); plans are in [docs/ROADMAP.md](docs/ROADMAP.md).

## Building from source

You need [Zig](https://ziglang.org/download/) 0.15.2 and Python 3. No Oracle files, compiler toolchain or CMake are needed.

```sh
git clone https://github.com/jamescook/duckdb-oracle.git
cd duckdb-oracle
zig build
```

This builds Windows x64, Windows ARM64 and Linux x64. The extension for each platform is `zig-out/<platform>/duckdb_oracle.duckdb_extension`
and the zip to distribute is `zig-out/dist/duckdb_oracle-<platform>.zip`, with `<platform>` one of `windows_amd64`, `windows_arm64`, `linux_amd64`. Build
just one with `zig build -Dplatform=windows_amd64`; macOS is `-Dplatform=osx_arm64`. Everything else (versions, options, tests, CI) is in
[docs/BUILDING.md](docs/BUILDING.md).

## License

MIT, see [LICENSE](LICENSE). Bundled third-party code keeps its own licenses (see [docs/BUILDING.md](docs/BUILDING.md#licenses)).
