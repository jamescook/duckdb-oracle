#!/usr/bin/env bash
# Create the objects the end-to-end tests need (test/e2e/setup/*): runs every *.sql file of the given
# directories with SQL*Plus, in order, as a privileged user (SYSTEM by default).
#
#   E2E_SETUP_PASSWORD=... tools/e2e-setup.sh HOST:PORT/SERVICE test/e2e/setup/common test/e2e/setup/23ai
#
# The password is passed to SQL*Plus on its standard input, never on the command line. A script that fails
# (WHENEVER SQLERROR EXIT FAILURE) stops the run with its exit code. Before the first script it waits for a
# login to work: a container's health check can turn green slightly before the PDB service is registered.
#
# Environment: E2E_SETUP_PASSWORD (required), E2E_SETUP_USER (default system), E2E_SETUP_WAIT (seconds, default 300),
#              SQLPLUS (the sqlplus binary, default `sqlplus`).
# These scripts create users and public synonyms: only run them against a throw-away database.
set -uo pipefail
dsn=${1:?usage: e2e-setup.sh HOST:PORT/SERVICE DIR...}
shift
[ "$#" -gt 0 ] || { echo "usage: e2e-setup.sh HOST:PORT/SERVICE DIR..." >&2; exit 2; }
: "${E2E_SETUP_PASSWORD:?E2E_SETUP_PASSWORD is not set}"
user=${E2E_SETUP_USER:-system}
wait_secs=${E2E_SETUP_WAIT:-300}
sqlplus_bin=${SQLPLUS:-sqlplus}

run() { printf '%s\n' "$E2E_SETUP_PASSWORD" | "$sqlplus_bin" -L -S "$user@//$dsn" "$@"; }

probe=$(mktemp)
trap 'rm -f "$probe"' EXIT
printf 'WHENEVER SQLERROR EXIT FAILURE\nSELECT 1 FROM dual;\nEXIT\n' > "$probe"
deadline=$((SECONDS + wait_secs))
until run "@$probe" > /dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "e2e-setup: no login to $dsn as $user within ${wait_secs}s" >&2
    exit 1
  fi
  echo "e2e-setup: waiting for $dsn ..." >&2
  sleep "${E2E_SETUP_RETRY:-5}"
done

for dir in "$@"; do
  [ -d "$dir" ] || { echo "e2e-setup: no such directory: $dir" >&2; exit 2; }
  found=0
  for f in "$dir"/*.sql; do
    [ -e "$f" ] || continue
    found=1
    echo "== $f"
    run "@$f"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "e2e-setup: $f failed (sqlplus exit code $rc)" >&2
      exit "$rc"
    fi
  done
  [ "$found" = 1 ] || { echo "e2e-setup: no .sql files in $dir" >&2; exit 2; }
done
echo "e2e-setup: done"
