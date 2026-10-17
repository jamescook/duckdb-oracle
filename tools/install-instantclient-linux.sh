#!/usr/bin/env bash
# Install Oracle Instant Client (Basic + SQL*Plus, the newest release) for x86-64 Linux into DEST and print the
# directory that holds libclntsh.so. For CI and for trying the extension on a Linux box.
#
#   tools/install-instantclient-linux.sh DEST
#
# Oracle publishes the newest release under a fixed name, so the download cannot be pinned by checksum
# (the DuckDB CLI, which can, is pinned: tools/duckdb-cli-pins.json). The client is only the thing under test's
# runtime dependency, never something that is shipped.
set -euo pipefail
dest="${1:?usage: install-instantclient-linux.sh DEST}"
base=https://download.oracle.com/otn_software/linux/instantclient
mkdir -p "$dest"
for pkg in basic sqlplus; do
  curl -fsSL --retry 4 --retry-delay 5 -o "$dest/instantclient-$pkg.zip" "$base/instantclient-$pkg-linuxx64.zip"
  unzip -qo "$dest/instantclient-$pkg.zip" -d "$dest"
  rm -f "$dest/instantclient-$pkg.zip"
done
ic=$(ls -d "$dest"/instantclient_* | sort | tail -1)

# Instant Client needs libaio.so.1; Ubuntu 24.04 renamed the package and the file (libaio1t64, libaio.so.1t64).
if ! ldconfig -p | grep -q 'libaio\.so\.1 '; then
  sudo apt-get install -y -q libaio1t64 >&2 || sudo apt-get install -y -q libaio1 >&2
  for f in /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /lib/x86_64-linux-gnu/libaio.so.1t64; do
    if [ -e "$f" ]; then ln -sf "$f" "$ic/libaio.so.1"; break; fi
  done
fi
test -e "$ic/libclntsh.so" || { echo "libclntsh.so not found in $ic" >&2; exit 1; }
echo "$ic"
