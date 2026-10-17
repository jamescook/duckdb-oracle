#!/usr/bin/env python3
"""Independent checker for the DuckDB extension metadata footer.

Mirrors DuckDB v1.5.6's ExtensionHelper::ParseExtensionMetaData: the last 512
bytes of the file are 8 x 32-byte metadata fields (stored in reverse order)
followed by a 256-byte signature area. The footer itself is written by the
vendored, unmodified extension-ci-tools append_extension_metadata.py; this
script only reads it back.

Usage: check_footer.py FILE [--platform P] [--version V] [--abi C_STRUCT]
Exit code 0 if the footer is valid and matches the expectations.
"""
import argparse
import sys

START_SIGNATURE = bytes([0, 147, 4, 16]) + b"duckdb_signature" + bytes([128, 4])


def parse(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 512 + len(START_SIGNATURE):
        raise SystemExit(f"{path}: too small to carry a footer")
    footer = data[-512:]
    start = data[-512 - len(START_SIGNATURE):-512]
    raw = footer[:256]
    fields = [raw[i * 32:(i + 1) * 32].rstrip(b"\x00").decode("ascii") for i in range(8)]
    fields.reverse()  # field 1 first
    return {
        "start_signature_ok": start == START_SIGNATURE,
        "magic": fields[0],
        "platform": fields[1],
        "duckdb_version": fields[2],
        "extension_version": fields[3],
        "abi_type": fields[4],
        "signature_empty": footer[256:] == b"\x00" * 256,
        "library_size": len(data) - 512 - len(START_SIGNATURE),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--platform")
    ap.add_argument("--version")
    ap.add_argument("--abi", default="C_STRUCT")
    args = ap.parse_args()
    m = parse(args.file)
    for k, v in m.items():
        print(f"{k:20} = {v}")
    ok = m["start_signature_ok"] and m["magic"] == "4" and m["abi_type"] == args.abi
    if args.platform:
        ok &= m["platform"] == args.platform
    if args.version:
        ok &= m["duckdb_version"] == args.version
    print("FOOTER OK" if ok else "FOOTER MISMATCH")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
