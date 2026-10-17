#!/usr/bin/env python3
"""Package one built extension for distribution.

DuckDB derives the extension name (and the init symbol it looks up,
<name>_init_c_api) from the file name, so the shipped file must be called
exactly `duckdb_oracle.duckdb_extension`. The platform therefore goes into the
*zip* name only:

    duckdb_oracle-<platform>.zip
      └── duckdb_oracle.duckdb_extension

The zip is deterministic (fixed timestamp/permissions), so identical inputs
give identical archives.

usage: package.py --extension <built file> --out <zip path>
"""
import argparse
import os
import sys
import zipfile

SHIPPED_NAME = "duckdb_oracle.duckdb_extension"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extension", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if os.path.basename(args.extension) != SHIPPED_NAME:
        sys.exit(f"refusing to package {args.extension!r}: the file must be named {SHIPPED_NAME}")
    with open(args.extension, "rb") as f:
        data = f.read()

    info = zipfile.ZipInfo(SHIPPED_NAME, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    info.create_system = 3  # unix, so the permissions above are honoured
    with zipfile.ZipFile(args.out, "w") as z:
        z.writestr(info, data, compresslevel=9)

    with zipfile.ZipFile(args.out) as z:  # self-check
        names = z.namelist()
        if names != [SHIPPED_NAME] or z.read(SHIPPED_NAME) != data:
            sys.exit(f"bad archive contents: {names}")


if __name__ == "__main__":
    main()
