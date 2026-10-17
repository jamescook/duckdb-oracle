# Roadmap

Ideas that are not implemented. None of this is promised.

* `ATTACH ... (TYPE oracle)` catalog integration
* DuckDB secrets (`CREATE SECRET (TYPE oracle)`)
* writes, DML and transactions: assessed against DuckDB's stable C API, with no clean path at the supported DuckDB floor (the `COPY ... TO` function API is stable only from 1.5.6); see [dev/WRITES.md](dev/WRITES.md)
* filter and projection pushdown
* session pooling (Oracle client `dpiPool`)
* bind parameters
* parallel scans (ROWID ranges)
* cancelling an Oracle call on interrupt (`dpiConn_breakExecution`)
* `OBJECT` type support (only `MDSYS.SDO_GEOMETRY` is supported, converted to WKB/WKT inside Oracle)
* `JSON` → DuckDB `JSON` logical type (needs the json extension's type alias)
* macOS and `linux_arm64` targets. The `osx_arm64` target already builds, but has never been loaded on a Mac and has no release zip;
  `linux_arm64` does not exist yet
* an ARM64EC build (could load the x64 `oci.dll` in a native ARM64 process, but needs an ARM64EC toolchain and an ARM64EC DuckDB)
* a signed community-extension distribution, which is blocked by the proprietary Oracle client runtime dependency
