# Vendored third-party code (pinned)

| Component | Version / ref | Source | Files |
|---|---|---|---|
| DuckDB C API headers | v1.5.6 (source_id 069cc9f9b5) | `libduckdb-src.zip` from https://github.com/duckdb/duckdb/releases/tag/v1.5.6 | `duckdb/v1.5.6/duckdb.h`, `duckdb/v1.5.6/duckdb_extension.h` (MIT, see `duckdb/LICENSE`) |
| ODPI-C | v26.0.0 (tag) | https://github.com/oracle/odpi | `odpi/` (`include/`, `src/`, `embed/`; UPL-1.0 / Apache-2.0, see `odpi/LICENSE.txt`) |
| extension-ci-tools | branch `v1.5.6` | https://github.com/duckdb/extension-ci-tools | `extension-ci-tools/append_extension_metadata.py` (MIT) - the official footer writer, used unmodified |

## ODPI-C pin review for Oracle 23ai / 26ai (2026-10-17)

`git ls-remote --tags https://github.com/oracle/odpi` shows **v26.0.0 is still the newest
release** (Sept 2026), so the pin is unchanged. It already provides everything duckdb-oracle needs
for 23ai/26ai server types: `DPI_ORACLE_TYPE_BOOLEAN`, native `JSON` (`dpiJson_getValue`,
`DPI_JSON_OPT_NUMBER_AS_STRING`), `DPI_ORACLE_TYPE_VECTOR` with `dpiVector_getValue` incl.
FLOAT32/FLOAT64/INT8/BINARY formats and sparse vectors (`dpiVectorInfo.isSparse`), the
`isOson` flag for OSON BLOB columns, and 26ai's three-digit version reporting. Minimum
client: 19c (dropped older clients in 6.0.0).
