#!/usr/bin/env bash
# Inspect a Windows artifact without running it (x64 or ARM64):
#  - PE32+ DLL with the machine type matching the platform
#    (windows_amd64 -> 0x8664 AMD64, windows_arm64 -> 0xAA64 ARM64)
#  - exports duckdb_oracle_init_c_api (the C Extension API entrypoint) and nothing else
#  - imports only Windows system DLLs (KERNEL32, ntdll, UCRT api-ms-win-crt-*)
#  - footer platform / C API version / C_STRUCT
# Uses tools/pe_inspect.py (pure Python) because Ubuntu's x86 objdump cannot
# parse ARM64 PE files.
# usage: tools/check-pe.sh <duckdb_oracle.duckdb_extension> [capi-version, default v1.2.0] [platform, default windows_amd64]
set -u
F=${1:?file}
VER=${2:-v1.2.0}
PLATFORM=${3:-windows_amd64}
DIR=$(cd "$(dirname "$0")" && pwd)
fail() { echo "FAIL: $*"; exit 1; }

case "$PLATFORM" in
  windows_amd64) want_machine=0x8664 ;;
  windows_arm64) want_machine=0xaa64 ;;
  *) fail "unknown platform $PLATFORM" ;;
esac

echo "== file type"
file -b "$F"
echo "== PE headers / exports / imports (tools/pe_inspect.py)"
python3 "$DIR/pe_inspect.py" "$F" || fail "not a PE file"
json=$(python3 "$DIR/pe_inspect.py" "$F" --json)
check() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if ($1) else 1)" "$json"; }
check "d['machine_raw']=='$want_machine'" || fail "machine is not $want_machine for $PLATFORM"
check "d['optional_header_magic'].startswith('0x20b')" || fail "not PE32+"
check "d['is_dll']" || fail "not a DLL"
check "d['exports']==['duckdb_oracle_init_c_api']" || fail "exports are not exactly [duckdb_oracle_init_c_api]"
check "all(__import__('re').fullmatch(r'(?i)(kernel32|ntdll|api-ms-win-crt-[a-z0-9-]+)\.dll', i) for i in d['imports'])" \
  || fail "non-system imports"
echo "machine OK ($want_machine), PE32+ DLL, exports OK, imports are system DLLs only"

echo "== footer"
python3 "$DIR/check_footer.py" "$F" --platform "$PLATFORM" --version "$VER" --abi C_STRUCT || fail "footer"
echo "PASS"
