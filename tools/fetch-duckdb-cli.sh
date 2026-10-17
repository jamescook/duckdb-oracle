#!/usr/bin/env bash
# Download the pinned official DuckDB CLI and verify its SHA-256 before using it.
# The version and checksums come from tools/duckdb-cli-pins.json (one place for all workflows).
#
# usage: tools/fetch-duckdb-cli.sh <linux-amd64|windows-amd64|windows-arm64> <destination dir>
# Prints the path of the CLI binary on success. Exits non-zero, deleting the download,
# on a checksum mismatch or if no checksum is pinned for the asset.
set -euo pipefail
platform=${1:?usage: fetch-duckdb-cli.sh <linux-amd64|windows-amd64|windows-arm64> <dest dir>}
dest=${2:?usage: fetch-duckdb-cli.sh <platform> <dest dir>}
pins=${DUCKDB_CLI_PINS:-"$(cd "$(dirname "$0")" && pwd)/duckdb-cli-pins.json"}

version=$(jq -er .version "$pins")
asset="duckdb_cli-$platform.zip"
want=$(jq -er --arg a "$asset" '.sha256[$a]' "$pins") || { echo "ERROR: no checksum pinned for $asset in $pins" >&2; exit 1; }

mkdir -p "$dest"
zip="$dest/$asset"
curl -fsSL -o "$zip" "https://github.com/duckdb/duckdb/releases/download/$version/$asset"
got=$(sha256sum "$zip" | cut -d' ' -f1)
if [ "$got" != "$want" ]; then
  rm -f "$zip"
  echo "ERROR: checksum mismatch for $asset $version" >&2
  echo "  pinned:     $want" >&2
  echo "  downloaded: $got" >&2
  exit 1
fi
unzip -qo "$zip" -d "$dest"
case "$platform" in windows-*) bin="$dest/duckdb.exe" ;; *) bin="$dest/duckdb"; chmod +x "$bin" ;; esac
echo "verified $asset $version (sha256 $got)" >&2
echo "$bin"
