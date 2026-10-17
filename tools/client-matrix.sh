#!/usr/bin/env bash
# Re-run acceptance checks 2 (stock-CLI load) and 3 (client present: version +
# unreachable DSN error) once per Oracle Instant Client directory.
#
# usage: tools/client-matrix.sh <duckdb> <duckdb_oracle-<platform>.zip | duckdb_oracle.duckdb_extension> [<instantclient dir> ...]
#   "none" as a directory means: no client on the library path.
set -u
DUCKDB=${1:?duckdb}; SRC=${2:?zip or extension}; shift 2
. "$(dirname "$0")/shipped-ext.sh"
resolve_shipped_ext "$SRC" || exit 1
[ $# -gt 0 ] || set -- none
rc=0
for IC in "$@"; do
  echo "################################################################"
  if [ "$IC" = none ]; then
    echo "# client: NONE (LD_LIBRARY_PATH unset)"; unset LD_LIBRARY_PATH
  else
    echo "# client: $IC"; export LD_LIBRARY_PATH="$IC"
  fi
  echo "## check 2: stock-CLI load test"
  "$(dirname "$0")/stock-cli-test.sh" "$DUCKDB" "$SRC" > /tmp/duckdb-oracle-matrix.log 2>&1
  c2=$?; tail -3 /tmp/duckdb-oracle-matrix.log; echo "stock-cli-test exit=$c2"; [ $c2 -eq 0 ] || rc=1
  echo "## oracle_client_info()"
  "$DUCKDB" -unsigned -line -c "LOAD '$EXT'; SELECT client_library_found, client_version, client_library_path, odpi_version, message FROM oracle_client_info();"
  echo "exit=$?"
  echo "## check 3: unreachable DSN must raise a DuckDB error with ORA-/DPI-"
  out=$(ORACLE_USER=scott ORACLE_PASSWORD=x "$DUCKDB" -unsigned -c "LOAD '$EXT'; SELECT * FROM oracle_query('127.0.0.1:1/NOPE', 'SELECT * FROM dual');" 2>&1)
  c3=$?; echo "$out" | grep -v '^LINE\|^ *\^\|^$'; echo "exit=$c3"
  if [ $c3 -ne 1 ] || ! echo "$out" | grep -Eq '(ORA|DPI)-[0-9]+'; then echo "UNEXPECTED"; rc=1; fi
done
exit $rc
