# Building and developing duckdb-oracle

This page is for people who build the extension from source or work on it. If you only want to use it, start with the
[README](../README.md).

## Pinned versions

| Component | Version | Where |
|---|---|---|
| Zig | **0.15.2** is the minimum (`build.zig.zon` `minimum_zig_version`) and the default for local builds; supported 0.15.2 .. 0.17.x. `ci.yml` builds with 0.17.0; the manual `zig-0.15.yml` and `windows.yml` also test 0.15.2 | `build.zig.zon`, `ci.yml`, `zig-0.15.yml`, `windows.yml` |
| DuckDB headers / tested baseline | **v1.5.6** (source_id `069cc9f9b5`) | C API headers vendored in `third_party/duckdb/v1.5.6/` |
| Target C API version (footer + `get_api`) | **v1.2.0** by default = minimum DuckDB version; `-Dduckdb-version=vX.Y.Z` to change | `build.zig` |
| ODPI-C | **v26.0.0** (git tag) | `third_party/odpi/` |
| Footer writer | `append_extension_metadata.py` from duckdb/extension-ci-tools branch **v1.5.6**, unmodified | `third_party/extension-ci-tools/` |
| SQLLogicTest runner | duckdb-sqllogictest-python @ `2ac8dbc0` (same pin as extension-ci-tools) + `duckdb==1.5.6` wheel | CI |
| Oracle Instant Client | tested on Linux: **Basic 19.26.0.0.0** (`instantclient-basic-linux.x64-19.26.0.0.0dbru.zip`) and **Basic 23.26.2.0.0** (the 23ai/26ai-generation client; what Oracle's "latest" permalink `instantclient-basic-linuxx64.zip` served on 2026-10-17, sha256 `4c17d54d…ea05`). Windows: x64 Basic 19.26 or 23ai/26ai | runtime only |

The vendored sources are listed, with their origin, in [`third_party/VERSIONS.md`](../third_party/VERSIONS.md).

`mise.toml` is git-ignored in this repository. If you use [mise](https://mise.jdx.dev/), a local `mise.toml` containing
`[tools]` / `zig = "0.15.2"` gives you the pinned compiler.

## Requirements

Zig 0.15.2 – 0.17.x and Python 3 (it runs the metadata-footer script). Nothing else is required: no Oracle SDK, no MSVC,
no CMake. `zig build` cross-compiles every platform from any host. The extension loads the Oracle client library
(`oci.dll` / `libclntsh.so`) at run time, so no Oracle files are needed to build it, and `LOAD` works without
Instant Client: you only get an error when an Oracle function actually runs.

## Build

```sh
zig build                        # default platforms, ReleaseSafe, C API target v1.2.0
#  -> zig-out/linux_amd64/duckdb_oracle.duckdb_extension
#  -> zig-out/windows_amd64/duckdb_oracle.duckdb_extension
#  -> zig-out/windows_arm64/duckdb_oracle.duckdb_extension   (aarch64-windows-gnu)
#  -> zig-out/dist/duckdb_oracle-<platform>.zip               (shipped form, one per platform)
zig build -Dplatform=windows_amd64        # just one
zig build -Dplatform=linux_amd64_gcc4     # Linux binary labelled for DuckDB v1.2.x Linux CLIs
zig build -Dplatform=osx_arm64            # Apple Silicon macOS: builds, but has never been loaded on a Mac
zig build -Dduckdb-version=v1.4.0         # target a specific (minimum) DuckDB version
```

Options: `-Dplatform=<name>` (repeatable; `linux_amd64`, `linux_amd64_gcc4`, `windows_amd64`, `windows_arm64`, `osx_arm64`),
`-Doptimize=Debug|ReleaseSafe|ReleaseFast` (default `ReleaseSafe`),
`-Dextension-version=v0.1.0` (the default comes from `git describe`, so an untagged build reports a commit hash such as
`042dc85`; build releases from a tag), `-Dduckdb-version=vX.Y.Z` (see [COMPATIBILITY.md](COMPATIBILITY.md#building-for-a-specific-duckdb-version);
`-Dcapi-version` is a deprecated alias), and `-Dpython=python3`. On Windows the build uses `python` instead of `python3`.

The default build produces `linux_amd64`, `windows_amd64` and `windows_arm64`. `linux_amd64_gcc4` and `osx_arm64` are built
only when asked for.

## Testing

```sh
zig build test                                     # Zig unit tests (type conversion, cursor, session, locator, ...)
zig build sqllogictest -Dpython=.venv/bin/python   # SQLLogicTests; needs the duckdb wheel (1.5.6 tested) + runner
python3 -m unittest discover -s tools              # the artifact verifier's own tests (it must FAIL on bad artifacts)
python3 tools/verify_artifact.py check zig-out/dist/duckdb_oracle-linux_amd64.zip --platform linux_amd64 \
    --duckdb ./duckdb --client none --client /path/to/instantclient_19_26   # name rule, footer, stock-CLI load, negative control, client checks
python3 tools/verify_artifact.py check zig-out/dist/duckdb_oracle-windows_amd64.zip --platform windows_amd64   # name rule, footer, PE machine/exports/imports
python3 tools/verify_artifact.py check zig-out/dist/duckdb_oracle-windows_amd64.zip --platform windows_amd64 \
    --duckdb duckdb.exe --wine wine64      # the official Windows CLI under Wine (a stand-in for Windows)
```

Other test scripts:

* `tools/timeout-test.sh <duckdb> <zip>`: a silent TCP listener must not hang the session (needs an Instant Client on the library path).
* `tools/windows-locator-test.sh <duckdb.exe> <zip> <instantclient_dir> [wine]`: the Windows client-library search scenarios
  (non-ASCII directories, current directory, relative `PATH`, 32-bit client, ...). Run under Wine on Linux or on Windows.
* `tools/live_oracle_test.py`: a Python script that runs queries against a **real Oracle server** (types, NULLs, `LIMIT`, LOBs,
  errors, timeouts). Manual only (no workflow runs it). It needs `ORACLE_DSN`, `ORACLE_USER`, `ORACLE_PASSWORD` and
  `DUCKDB_ORACLE_EXTENSION` in the environment and the `duckdb` Python wheel.
* `test-windows.ps1`: the Windows test, used both by hand and by CI (`windows.yml`, `e2e-oracle19c.yml`), so local and CI runs are
  identical. Without Oracle (`-SkipOracle`) it downloads the pinned, checksum-verified DuckDB CLI, unpacks the shipped zip, checks
  that the CLI does not already contain the extension, shows which `oci.dll` would load, `LOAD`s the extension under its exact
  shipped file name and runs `oracle_client_info()`. With a database it also runs the end-to-end SQL tests below. Useful switches:
  `-Strict` (CI mode: skipped Oracle steps, a missing or wrong-architecture `oci.dll` and architecture warnings are failures),
  `-WaitForDatabase <seconds>`, `-Dsn` / `-User` (default `$env:ORACLE_DSN` / `$env:ORACLE_USER`; the password is read only from
  `$env:ORACLE_PASSWORD`), `-DuckDB <path>` (use your own CLI instead of downloading one), `-E2EDir`. See `Get-Help .\test-windows.ps1 -Full`.
  Optional 23ai/26ai database (for example `docker run -d -p 1522:1521 -e ORACLE_PASSWORD=... gvenzl/oracle-free`): set
  `$env:ORACLE_DSN_23AI = 'localhost:1522/FREEPDB1'`, `$env:ORACLE_PASSWORD_23AI` (falls back to `ORACLE_PASSWORD`) and optionally
  `$env:ORACLE_USER_23AI` (default `SYSTEM`). It then runs the same tests against that server, plus `test/e2e/23ai` (BOOLEAN, JSON,
  VECTOR) if the loaded client is 23ai or newer.

### End-to-end SQL tests (`test/e2e`)

Plain `.sql` files, one DuckDB process each, run in file-name order against a real database by `test-windows.ps1` (Windows: the self-hosted runner, or by hand) or by `tools/e2e_run.py` (Linux: the hosted `e2e-oracle` job; both apply the same rules to the same files): `SELECT FROM
dual`, one test per mapped type built from literals and `CAST` on `dual` (NUMBER variants, `BINARY_FLOAT`/`DOUBLE`,
`VARCHAR2`/`NVARCHAR2`/`CHAR`/`CLOB`, `DATE`, `TIMESTAMP`, time zones, intervals, `RAW`/`BLOB`/`ROWID`), NULLs, a 6000-row query that
crosses DuckDB vector boundaries, `LIMIT` early termination, and Oracle errors that must surface `ORA-` codes while the process keeps
running. They need no tables, only `CREATE SESSION`. Conventions:

* `@DSN@` is replaced by the connect string. The login is never in SQL: it comes from `ORACLE_USER` / `ORACLE_PASSWORD`.
* A test builds a temp table from `oracle_query`, lists named checks one per line, and ends with one statement that calls DuckDB's
  `error()` naming every failed check. Exit code 0 means every check held.
* Header comments control the judgement: `-- expect-error: <regex>` (the run must fail with matching output, and the file starts with
  `.bail off` so later statements still run, which proves the process survives), `-- expect-output: <regex>`,
  `-- timeout: <seconds>`, `-- optional` (a failure is a warning).
* `test/e2e/23ai/` holds the tests that need a 23ai/26ai server and client (`BOOLEAN`, `JSON`, `VECTOR` built from literals).
* `test/e2e/needs-setup/` holds the tests that need objects created by `test/e2e/setup/` first: `needs-setup/23ai` (VECTOR tables with declared types) and `needs-setup/schema` (`oracle_scan`, `oracle_tables` and `current_schema` against a second schema, private and public synonyms, a shadowed name and a case-sensitive table). `test-windows.ps1` does not run this directory.
* `test/e2e/setup/<group>/*.sql` are SQL*Plus scripts that create the objects such tests need (see its README). `tools/e2e-setup.sh` runs them as SYSTEM, on a throw-away database only.
* `test/e2e/spatial/` holds the `SDO_GEOMETRY` tests. They are built from constructors on `dual` like the others and need Oracle
  Locator (the first file, `00_probe_locator.sql`, checks for it) and DuckDB's `ST_GeomFromWKB`/`ST_AsText` (core in DuckDB 1.5).

Run them on Linux by hand with the pinned CLI, the extension from the zip and an Instant Client on `LD_LIBRARY_PATH`:

```sh
export ORACLE_USER=... ORACLE_PASSWORD=...        # the password is read from the environment only
tools/e2e_run.py --duckdb "$(tools/fetch-duckdb-cli.sh linux-amd64 /tmp/duckdb-cli)" \
  --extension /path/to/duckdb_oracle.duckdb_extension --dsn localhost:1521/FREEPDB1 --wait 120 \
  test/e2e test/e2e/spatial
```
(`tools/install-instantclient-linux.sh DEST` downloads Instant Client and prints the directory to put on `LD_LIBRARY_PATH`.)

## Distribution: one zip per platform

DuckDB derives the extension name, and the init symbol it resolves (`<name>_init_c_api`), from the
**file name**. The file therefore has to be called exactly `duckdb_oracle.duckdb_extension`. A platform
suffix in the file name breaks `LOAD` with `did not contain function "duckdb_oracle-<platform>_init_c_api"`.
So each platform ships as a zip, with the platform in the zip name only (see the table in
[COMPATIBILITY.md](COMPATIBILITY.md#which-zip-do-i-need)).

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

* `build.zig.zon` sets `minimum_zig_version = "0.15.2"`; 0.15.2 is the default toolchain and builds the released artifacts.
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
* Other things that do not exist on 0.17 and so must not be used in new code: the `**` array-repeat operator (use `@splat`),
  `@typeInfo(enum).fields`, and `std.ascii.indexOfIgnoreCase`.
* `ci.yml` builds and tests with Zig 0.17 on every push; the manual `zig-0.15.yml` runs the same steps with 0.15.2, and `windows.yml` builds on Windows with both.

```sh
zig build && zig build test                                  # default (0.15.2)
/path/to/zig-0.17.0/zig build && /path/to/zig-0.17.0/zig build test
```

## Continuous integration

Exactly four workflows live in `.github/workflows/`. The build and test steps shared by `ci.yml` and `zig-0.15.yml` are one composite
action, `.github/actions/build-test`, so the two cannot drift apart.

| Workflow | Trigger | Runner | What it checks |
|---|---|---|---|
| `ci.yml` | automatic on pull requests and on pushes to branches other than `main` (the `branches-ignore: [main]` filter can be removed to bring the push-to-`main` run back); also manual | `ubuntu-latest`, Zig 0.17 | `zig build test`; builds all five platform targets (Windows and macOS cross-compiled); the artifact verifier's own tests; for each platform the shipped name, metadata footer and, for Windows, the PE image; every `-Dduckdb-version` in range compiles; loads the `linux_amd64` build into the stock DuckDB CLI (pinned version, checksum-verified) with the negative control; SQLLogicTests. **Uploads each platform's shipped zip as the artifact `duckdb_oracle-<platform>`**. A second job, `e2e-oracle`, then loads that `linux_amd64` build into the pinned stock CLI and runs the end-to-end SQL tests against real databases started as service containers: **Oracle Free 23ai** (`gvenzl/oracle-free:23-slim`: `test/e2e`, `test/e2e/spatial`, `test/e2e/23ai`, then `test/e2e/needs-setup/23ai` and `.../schema` after the scripts in `test/e2e/setup/common` and `.../23ai`) and **Oracle XE 21c** (`gvenzl/oracle-xe:21-slim`: `test/e2e`, `test/e2e/spatial`, `.../needs-setup/schema` after `.../setup/common`), with the newest Instant Client |
| `zig-0.15.yml` | manual (`workflow_dispatch`) | `ubuntu-latest`, Zig 0.15.2 | the same steps as `ci.yml`, to keep the compat layer honest; uploads nothing |
| `windows.yml` | manual | `windows-latest`, Zig 0.15.2 and 0.17 | builds `windows_amd64` natively, then `test-windows.ps1 -SkipOracle` (PowerShell 7 and Windows PowerShell 5.1): downloads the pinned official DuckDB CLI and verifies its checksum, `LOAD`s the extension under its exact shipped file name, `duckdb_extensions()` shows it loaded, `oracle_client_info()` runs |
| `e2e-oracle19c.yml` | manual, **owner only** (`github.actor == 'jamescook'`) | self-hosted `[self-hosted, windows, oracle19c]` | the real-database end-to-end tests (`test/e2e`) against Oracle 19c, using the build from the latest successful `ci.yml` run on `main`. Setup: [SELF_HOSTED_RUNNER.md](SELF_HOSTED_RUNNER.md) |

The DuckDB CLI version and the SHA-256 of its official release assets are pinned in one file, `tools/duckdb-cli-pins.json`, used by every
workflow (`tools/fetch-duckdb-cli.sh` on Linux, `test-windows.ps1` on Windows). To move to another DuckDB release, change the version and
the checksums there (compare them with the digests GitHub shows on the release page).

Checks that used to run in CI and now run only by hand: the Oracle Instant Client matrix (`verify_artifact.py --client DIR`), the
silent-listener timeout test (`tools/timeout-test.sh`), the Windows client-library scenarios under Wine
(`tools/windows-locator-test.sh`), the Windows ARM64 runner job, the loads into older DuckDB releases, and
`tools/live_oracle_test.py` (an older, smaller live test that `test/e2e` and the `e2e-oracle` job now supersede).

## Project layout

```
build.zig, build.zig.zon     Zig build (cross-compile + footer + tests)
build_compat.zig             Zig-version shims for the build script (0.15.2 .. 0.17.x)
src/compat.zig               Zig-version shims for the extension code
src/c_headers.h              C headers translated by b.addTranslateC (module "c_headers")
src/duckdb_oracle.zig        entrypoint (duckdb_oracle_init_c_api), table functions, DuckDB vectors
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
tools/verify_artifact.py     the artifact rules in one place: name, footer, PE, stock-CLI load, negative control, client checks (+ tests)
tools/windows-locator-test.sh Windows client-locator scenarios with the real Windows duckdb.exe + Instant Client (Wine or Windows)
tools/                       package.py (zip packaging, owns the shipped name), pe_inspect.py (x64+ARM64), check_footer.py, timeout-test.sh, live_oracle_test.py,
                             duckdb-cli-pins.json (pinned DuckDB CLI version + checksums), fetch-duckdb-cli.sh, install-instantclient-linux.sh, e2e_run.py (the Linux e2e runner), e2e-setup.sh (runs test/e2e/setup),
                             test_ci_config.py (guards the workflow contract), test_e2e_run.py, test_e2e_setup.py
test/e2e/                    end-to-end SQL tests run against a real Oracle database by test-windows.ps1 and tools/e2e_run.py (23ai/ for 23ai/26ai, spatial/ for SDO_GEOMETRY)
test-windows.ps1             Windows test: pinned stock CLI, oci.dll check, LOAD, and the end-to-end tests (used by hand and by CI)
third_party/                 vendored DuckDB headers, ODPI-C, metadata script (see third_party/VERSIONS.md)
.github/workflows/           ci.yml, zig-0.15.yml, windows.yml, e2e-oracle19c.yml (see Continuous integration)
.github/actions/build-test   the build-and-test steps shared by ci.yml and zig-0.15.yml
docs/SELF_HOSTED_RUNNER.md   registering the runner for e2e-oracle19c.yml
docs/dev/REPORT.md           development log of the original verification (history, not user documentation)
docs/dev/WRITES.md           assessment: writing to Oracle through the stable C API (no clean path at the supported floor)
```

## Licenses

duckdb-oracle is MIT licensed (`LICENSE`). Vendored code keeps its own licenses:
ODPI-C is under UPL-1.0 / Apache-2.0 (`third_party/odpi/LICENSE.txt`). The DuckDB headers and
extension-ci-tools script are MIT.
