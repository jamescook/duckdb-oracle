#!/usr/bin/env bash
# Stock-CLI load test: load the *external* duckdb-oracle binary into an unmodified
# official DuckDB CLI and require exit code 0 + loaded=true.
#
# The extension is loaded under its exact shipped file name:
# usage: tools/stock-cli-test.sh <path/to/duckdb> <duckdb_oracle-<platform>.zip | .../duckdb_oracle.duckdb_extension>
set -u
DUCKDB=${1:?duckdb binary}
SRC=${2:?zip or extension file}

fail() { echo "FAIL: $*"; exit 1; }
. "$(dirname "$0")/shipped-ext.sh"
echo "== 0. shipped artifact: $SRC"
resolve_shipped_ext "$SRC" || fail "artifact is not shippable as-is"
[ "$(basename "$EXT")" = "duckdb_oracle.duckdb_extension" ] || fail "unexpected file name $EXT"

echo "== DuckDB CLI: $DUCKDB"
"$DUCKDB" -c "SELECT version() AS version, source_id FROM pragma_version();" || fail "duckdb does not run"

echo "== 1. duckdb_oracle must not be built in / preloaded"
pre=$("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM duckdb_extensions() WHERE extension_name='duckdb_oracle' AND (loaded OR installed); SELECT count(*) FROM duckdb_functions() WHERE function_name LIKE 'oracle_%';" | tr -d '\r' | paste -sd,)
echo "   (preloaded/installed rows, oracle_* functions) = $pre"
[ "$pre" = "0,0" ] || fail "duckdb_oracle is already present in this DuckDB"

echo "== 2. LOAD the external binary (brief's acceptance command)"
"$DUCKDB" -unsigned -c "LOAD '$EXT'; SELECT * FROM duckdb_extensions() WHERE extension_name='duckdb_oracle'; SELECT * FROM oracle_client_info();"
code=$?
printf '   exit code: %d (0x%08X)\n' "$code" "$code"
[ "$code" -eq 0 ] || fail "non-zero exit code"

loaded=$("$DUCKDB" -unsigned -csv -noheader -c "LOAD '$EXT'; SELECT loaded FROM duckdb_extensions() WHERE extension_name='duckdb_oracle';" | tr -d '\r')
echo "   loaded = $loaded"
[ "$loaded" = "true" ] || fail "duckdb_extensions() does not report loaded=true"

echo "PASS"
