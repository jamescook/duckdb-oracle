#!/usr/bin/env bash
# Regression test for the "hang with no timeout" defect (review F3).
# Needs a real Oracle Instant Client on the library path (the hang is inside OCI),
# python3 and a DuckDB CLI. A local TCP server accepts connections and never
# answers, which is how a dead listener or a silently dropping firewall behaves.
#
# usage: tools/timeout-test.sh <duckdb> <duckdb_oracle-<platform>.zip | duckdb_oracle.duckdb_extension>
set -u
DUCKDB=${1:?duckdb binary}
SRC=${2:?zip or extension file}
fail() { echo "FAIL: $*"; exit 1; }
EXT=$(python3 "$(dirname "$0")/verify_artifact.py" extract "$SRC") || fail "artifact is not shippable as-is"

PORT=$((20000 + RANDOM % 20000))
python3 - "$PORT" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
keep = []
while True:
    keep.append(s.accept()[0])
PY
SRV=$!
cleanup() { kill $SRV 2>/dev/null; case "$SRC" in *.zip) rm -rf "$(dirname "$EXT")" ;; esac; }
trap cleanup EXIT
sleep 1

run() { # <seconds budget> <sql>; prints elapsed seconds and output
  local start end out
  start=$(date +%s)
  out=$(ORACLE_USER=u ORACLE_PASSWORD=p timeout -s KILL "$1" "$DUCKDB" -unsigned -c "LOAD '$EXT'; $2" 2>&1)
  RC=$?; end=$(date +%s); ELAPSED=$((end - start)); OUT=$out
}

echo "== explicit connect_timeout := 2 must fail with ORA-12170 within 10 s"
run 20 "SELECT * FROM oracle_query('127.0.0.1:$PORT/X', 'select 1 from dual', connect_timeout := 2);"
echo "   rc=$RC elapsed=${ELAPSED}s"
[ "$RC" -eq 1 ] || fail "expected a DuckDB error (exit 1), got $RC (137 = still hanging when killed)"
[ "$ELAPSED" -le 10 ] || fail "took ${ELAPSED}s"
echo "$OUT" | grep -q "ORA-12170" || fail "no ORA-12170 in: $OUT"
echo "$OUT" | grep -q "connect_timeout :=" || fail "no hint in: $OUT"

echo "== a DSN that already sets connect_timeout is honoured"
run 20 "SELECT * FROM oracle_query('127.0.0.1:$PORT/X?connect_timeout=2', 'select 1 from dual');"
[ "$RC" -eq 1 ] && [ "$ELAPSED" -le 10 ] || fail "rc=$RC elapsed=${ELAPSED}s"

echo "== invalid values are rejected at bind"
run 20 "SELECT * FROM oracle_query('127.0.0.1:$PORT/X', 'select 1 from dual', timeout := -1);"
echo "$OUT" | grep -q "must be between 0 and" || fail "negative timeout accepted: $OUT"

echo "== the DEFAULT (no timeout argument) is bounded: must end before the 60 s budget"
run 60 "SELECT * FROM oracle_query('127.0.0.1:$PORT/X', 'select 1 from dual');"
echo "   rc=$RC elapsed=${ELAPSED}s"
[ "$RC" -eq 1 ] || fail "default connect is not bounded (rc=$RC)"
echo "PASS"
