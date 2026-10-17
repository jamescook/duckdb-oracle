//! C headers: DuckDB C Extension API (vendored v1.5.6 headers; the target API
//! version is selected with DUCKDB_EXTENSION_API_VERSION_* from -Dduckdb-version)
//! and ODPI-C. Translated by the build system (src/c_headers.h ->
//! b.addTranslateC -> module "c_headers"), which works on every supported Zig
//! version, unlike @cImport (removed in Zig 0.17).
pub const c = @import("c_headers");
