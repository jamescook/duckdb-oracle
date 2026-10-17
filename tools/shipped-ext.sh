# Sourced by the test scripts. resolve_shipped_ext <zip-or-file> sets EXT to the
# path of the extension exactly as shipped, or fails.
#   - duckdb_oracle-<platform>.zip: extracted as-is into a fresh temp dir; the
#     archive must contain exactly one entry, duckdb_oracle.duckdb_extension.
#   - a .duckdb_extension file: must already be named duckdb_oracle.duckdb_extension.
# Nothing is ever renamed, so a wrongly named artifact fails the test (DuckDB
# derives <name>_init_c_api from the file name).
SHIPPED_NAME=duckdb_oracle.duckdb_extension
resolve_shipped_ext() {
  local src=$1
  case "$src" in
    *.zip)
      local dir; dir=$(mktemp -d /tmp/duckdb-oracle-pkg.XXXXXX)
      python3 - "$src" "$dir" "$SHIPPED_NAME" <<'PY' || return 1
import sys, zipfile
src, dest, want = sys.argv[1:4]
with zipfile.ZipFile(src) as z:
    names = z.namelist()
    if names != [want]:
        sys.exit(f"FAIL: {src} must contain exactly [{want}], found {names}")
    z.extractall(dest)
PY
      EXT="$dir/$SHIPPED_NAME"
      echo "   package: $src -> $EXT"
      ;;
    *)
      if [ "$(basename "$src")" != "$SHIPPED_NAME" ]; then
        echo "FAIL: '$src' is not named $SHIPPED_NAME; DuckDB would look for '$(basename "$src" .duckdb_extension)_init_c_api'"
        return 1
      fi
      EXT=$src
      ;;
  esac
}
