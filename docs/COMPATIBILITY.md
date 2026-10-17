# Compatibility

Which DuckDB, Windows, Linux, macOS and Oracle versions work, and why. For setup instructions see the
[README](../README.md).

## Which zip do I need?

Each platform ships as a zip with the platform in the zip name only. Inside is always one file, named exactly
`duckdb_oracle.duckdb_extension`. Load it as unzipped; don't rename it.

| Download | Contains | For |
|---|---|---|
| `duckdb_oracle-windows_amd64.zip` | `duckdb_oracle.duckdb_extension` | Windows x64, and Windows ARM through x64 emulation |
| `duckdb_oracle-windows_arm64.zip` | `duckdb_oracle.duckdb_extension` | native Windows ARM64 DuckDB (see [Windows on ARM](#windows-on-arm)) |
| `duckdb_oracle-linux_amd64.zip` | `duckdb_oracle.duckdb_extension` | Linux x86-64, DuckDB 1.3+ |
| `duckdb_oracle-linux_amd64_gcc4.zip` | `duckdb_oracle.duckdb_extension` | Linux x86-64, DuckDB 1.2.x (platform `linux_amd64_gcc4`) |

Why the file name matters: DuckDB derives the extension name, and the entry point it looks up (`<name>_init_c_api`), from the
file name. A platform suffix in the file name breaks `LOAD` with
`did not contain function "duckdb_oracle-<platform>_init_c_api"`.

**macOS (Apple Silicon):** there is no prebuilt zip. `zig build -Dplatform=osx_arm64` produces a valid arm64 Mach-O extension with the
right metadata, but it has never been loaded on a Mac. Oracle publishes a macOS ARM64 Instant Client. Treat macOS as untested.

## DuckDB versions

The extension uses only the **stable** C Extension API (ABI type `C_STRUCT`). For this ABI type,
the file's metadata footer does **not** record a specific DuckDB release. Its version field holds the **minimum
C API version**, and DuckDB accepts the file on any 1.x release at or above it. Every function duckdb-oracle calls
is in the v1.2.0 stable surface, so the default build targets **v1.2.0**, the first release with the C
Extension API. **v1.5.6 is the tested baseline**: its headers are vendored and the full test suite ran against it.

| Official DuckDB CLI | linux_amd64 (default build) | windows_amd64 (default build) |
|---|---|---|
| v1.5.0 – v1.5.6 (newest at time of writing) | ✅ loaded (tested v1.5.0, v1.5.6) | ✅ v1.5.6 under Wine; CI matrix |
| v1.3.x, v1.4.x | ✅ loaded (tested v1.3.2, v1.4.5) | CI matrix (v1.3.2, v1.4.5) |
| v1.2.x | ⚠️ these Linux CLIs report platform `linux_amd64_gcc4`. Use the `linux_amd64_gcc4` zip (or `-Dplatform=linux_amd64_gcc4`): the library bytes are identical and only the footer label differs. Alternatively, load the unchanged file after `SET allow_extensions_metadata_mismatch=true;`. Both tested on v1.2.0 and v1.2.2 | ✅ v1.2.0 under Wine; CI matrix |
| ≤ v1.1.x | ❌ no C Extension API. Rejected cleanly ("built for DuckDB C API version 'v1.2.0'") | ❌ |
| 2.x (does not exist yet) | ❌ C API major version must be 1 | ❌ |

Linux binaries are built against glibc 2.28 (the baseline DuckDB's own Linux builds use), so they load on older distributions.

### Building for a specific DuckDB version

`zig build -Dduckdb-version=v1.4.0` produces a binary that loads on 1.4.0 and newer 1.x releases. Allowed values run from
`v1.2.0` to `v1.5.6`, the vendored headers. Because the headers gate every function by version, targeting an older version makes
any use of a newer API a compile error, so the build itself proves the minimum version is correct. Supporting releases newer
than 1.5.6 needs no rebuild: the default binary already loads there (forward compatibility of the stable C API).
Targeting a C API *above* 1.5.6 would mean vendoring that release's headers into `third_party/duckdb/<ver>/` and updating
`duckdb_headers_version` in `build.zig`.

### Why `x86_64-windows-gnu`

Only a plain C ABI crosses the DuckDB ↔ extension boundary: the `duckdb_extension_access`
struct and the versioned function-pointer struct. No C++ objects, exceptions or STL types
cross it, so the MSVC requirement for C++ DuckDB extensions does not apply (and a C++ entry-point mismatch between extension and
DuckDB build cannot happen). Zig ships the MinGW-w64 CRT and builds it against the Windows UCRT. The resulting DLL imports only
`KERNEL32.dll`, `ntdll.dll` and the `api-ms-win-crt-*` UCRT API sets, which are part of
Windows 10 and later (`tools/verify_artifact.py` enforces this). No libgcc, libstdc++ or
vcruntime DLL is needed. The footer platform is the standard `windows_amd64`, which the
official CLI accepts. `windows_amd64_mingw` exists only for C++-ABI extensions built for
MinGW DuckDB builds.

## How Windows finds Oracle's `oci.dll`

On Windows the extension itself decides which `oci.dll` loads (`src/client_locator.zig`), in this order:

1. `DUCKDB_ORACLE_CLIENT_LIB_DIR` (exclusively, if set; nothing else is tried).
2. Otherwise: the extension's own directory, the directory of `duckdb.exe`, then each **absolute** entry of `PATH`.

**The current directory and relative `PATH` entries are never searched**, so a stray `oci.dll` in the folder you start DuckDB from
is not loaded. An `oci.dll` of the wrong architecture (for example a 32-bit client) is skipped and named in the message, and the
search goes on, so the order of a 32-bit and a 64-bit client on `PATH` does not matter. Paths are handled as Unicode, so
directories with non-ASCII characters work. `oracle_client_info()` reports where `oci.dll` was loaded from. If `oci.dll` loads but
the rest of the Instant Client is missing next to it, the message says where it was loaded from and that all Instant Client files
must be in that directory.

On Linux the normal dynamic loader finds `libclntsh.so` (`LD_LIBRARY_PATH`, `ldconfig`, `$ORACLE_HOME/lib`); set
`DPI_DEBUG_LEVEL=64` before starting DuckDB to trace the search.

## Windows on ARM

**Oracle does not publish an Instant Client for Windows ARM64**, as far as could be determined on
2026-10-17. Windows downloads exist for x64 and 32-bit x86 only, and ARM64 builds exist only for Linux and macOS.
The evidence is in [dev/REPORT.md](dev/REPORT.md#83-oracle-instant-client-for-windows-arm64-none-found). A native ARM64 process
cannot load an x64 `oci.dll`. As a result, the `windows_arm64` build loads fine into the
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
architecture of the first `oci.dll` met when that doesn't match the process. `test-windows.ps1` detects an ARM64 host and checks
that duckdb.exe, the extension and the first `oci.dll` all share one architecture, warning on any mismatch. It downloads the x64
CLI by default; use `-DuckDBArch arm64` for the native one.

## Oracle server and client versions

* **Oracle Database 19c** is the primary target; **23ai/26ai** is secondary. No 19c server is used in the automated tests. The
  `live-oracle` CI job runs real queries against Oracle Free 23ai (see [BUILDING.md](BUILDING.md#continuous-integration)).
* **Instant Client** 19c or newer. Tested on Linux with **Basic 19.26.0.0.0** and **Basic 23.26.2.0.0**. On Windows the maintainer
  used x64 Basic 19.26, and the 23ai-generation Windows client has been loaded and exercised up to the connect step (the automated
  Windows runs use Wine). Oracle's interoperability rules allow a newer client to connect to an older server (for example a 23ai
  client to 19c); this project's tests have not exercised that combination.
* Instant Client 19 on Windows needs the Visual Studio 2017 (or later) x64 C++ runtime.
* The 23ai/26ai column types (`BOOLEAN`, `VECTOR`, native `JSON`) only work if the **client** understands them: see
  [TYPES.md](TYPES.md#client-requirements-for-23ai26ai-types). On a 19c server none of those types can occur, so 19c behaviour
  does not depend on them.
* Oracle's client libraries are proprietary and are not shipped with this extension, which is also why a signed
  community-extension distribution is not possible (see [ROADMAP.md](ROADMAP.md)).
