#!/usr/bin/env bash
# Windows client-library locator scenarios (review F4, F7 and the search policy in
# src/client_locator.zig), run with the OFFICIAL Windows duckdb.exe, the shipped
# windows_amd64 extension and Oracle's REAL Windows Instant Client oci.dll.
#
# Runs under Wine on a Linux host; Wine is a stand-in for Windows, not Windows.
# The same scenarios are worth running on a real Windows host (PowerShell, same
# environment variables).
#
# usage: tools/windows-locator-test.sh <duckdb.exe> <duckdb_oracle-windows_amd64.zip|extension> <instantclient_dir> [wine-command]
#   instantclient_dir: unzipped instantclient-basic-windows.zip (contains oci.dll)
#   wine-command:      default "wine64" (e.g. /usr/lib/wine/wine64)
set -u
DUCKDB=$(readlink -f "${1:?duckdb.exe}")
SRC=${2:?extension zip or file}
IC=$(readlink -f "${3:?instantclient dir}")
WINE=${4:-wine64}
export WINEPREFIX=${WINEPREFIX:-/tmp/wineprefix-locator} WINEDEBUG=-all WINEARCH=win64 DISPLAY= LANG=C.UTF-8

. "$(dirname "$0")/shipped-ext.sh"
resolve_shipped_ext "$SRC" || { echo "FAIL: artifact is not shippable as-is"; exit 1; }
[ -f "$IC/oci.dll" ] || { echo "FAIL: $IC/oci.dll not found"; exit 1; }

W=$(mktemp -d /tmp/locator-test.XXXXXX)
winpath() { printf 'Z:%s' "$(echo "$1" | sed 's#/#\\#g')"; }   # /tmp/x -> Z:\tmp\x
mkdir -p "$W"/{ascii,"Müller-é",cwd,x86,extdir,empty}
cp -r "$IC"/. "$W/ascii/"; cp -r "$IC"/. "$W/Müller-é/"; cp "$IC"/*.dll "$W/cwd/"
cp -r "$IC"/. "$W/extdir/"; cp "$EXT" "$W/extdir/duckdb_oracle.duckdb_extension"
# a genuine 32-bit PE named oci.dll (any x86 DLL: only the PE header matters)
X86=$(find / -path '*i386-windows/*.dll' 2>/dev/null | head -1)
[ -n "$X86" ] && cp "$X86" "$W/x86/oci.dll"

# first use creates the Wine prefix, which prints noise; do it before any scenario
"$WINE" "$DUCKDB" -c "SELECT 1" >/dev/null 2>&1

Q="SELECT client_library_found AS found, client_library_path AS path, message AS msg FROM oracle_client_info();"
# check() runs in a pipeline subshell, so failures are counted in a file
: > "$W/.fails"
check() { # <name> <expected found> <substring expected in path/message or ''>   (reads csv on stdin)
  local out found; out=$(cat); found=$(echo "$out" | sed -n 2p | cut -d, -f1)
  if [ "$found" = "$2" ] && { [ -z "${3:-}" ] || echo "$out" | grep -qF -- "$3"; }; then echo "PASS  $1"
  else echo "FAIL  $1  (found=$found, wanted $2 ${3:+containing '$3'})"; echo "$out" | sed -n 2,3p | cut -c1-500; echo x >> "$W/.fails"; fi
}
run() { local dir=$1 ext=$2; shift 2; ( cd "$dir" && env "$@" "$WINE" "$DUCKDB" -unsigned -csv -c "LOAD '$ext'; $Q" 2>&1 ); }

echo "== explicit directory"
run "$W/cwd" "$EXT" DUCKDB_ORACLE_CLIENT_LIB_DIR="$(winpath "$W/ascii")"      | check "DUCKDB_ORACLE_CLIENT_LIB_DIR, ASCII path" true ascii
run "$W/cwd" "$EXT" DUCKDB_ORACLE_CLIENT_LIB_DIR="$(winpath "$W/Müller-é")"   | check "F4: DUCKDB_ORACLE_CLIENT_LIB_DIR with non-ASCII characters" true Müller
run "$W/cwd" "$EXT" DUCKDB_ORACLE_CLIENT_LIB_DIR="$(winpath "$W/empty")" WINEPATH="$(winpath "$W/ascii")" \
                                                                              | check "LIB_DIR is exclusive: empty dir there, a client on PATH is NOT used" false DUCKDB_ORACLE_CLIENT_LIB_DIR
echo "== PATH"
run "$W/cwd" "$EXT" WINEPATH="$(winpath "$W/ascii")"                          | check "PATH entry" true ascii
run "$W/cwd" "$EXT" WINEPATH="$(winpath "$W/Müller-é")"                       | check "PATH entry with non-ASCII characters" true Müller
echo "== current directory is never searched (F7)"
run "$W/cwd" "$EXT"                                                           | check "oci.dll only in the current directory is not loaded" false "never searched"
run "$W/cwd" "$EXT" WINEPATH=".;relative\\bin"                                | check "'.' and relative PATH entries do not enable the current directory" false
run "$W/cwd" "$EXT" WINEPATH="$(winpath "$W/ascii")"                          | check "current directory holds a client AND PATH holds another: PATH one wins" true ascii
echo "== extension directory first"
run "$W/cwd" "$W/extdir/duckdb_oracle.duckdb_extension"                       | check "oci.dll next to the extension is used" true extdir
if [ -f "$W/x86/oci.dll" ]; then
echo "== wrong architecture"
run "$W/x86" "$EXT" WINEPATH="$(winpath "$W/x86");$(winpath "$W/ascii")"      | check "32-bit oci.dll first on PATH is skipped; the 64-bit one after it loads" true ascii
run "$W/x86" "$EXT" WINEPATH="$(winpath "$W/x86")"                            | check "only a 32-bit oci.dll: not found, the file and its architecture are named" false "oci.dll is x86"
fi
echo "== client files missing next to oci.dll"
mkdir -p "$W/stub"; cp "$IC/oci.dll" "$W/stub/"
run "$W/cwd" "$EXT" WINEPATH="$(winpath "$W/stub")"                           | check "oci.dll loads but the client is incomplete: message says where it was loaded from" false "was loaded from"

fails=$(wc -l < "$W/.fails")
rm -rf "$W"
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL: $fails scenario(s)"; exit 1; }
