#!/usr/bin/env python3
"""Minimal PE/COFF inspector (no dependencies; works for x64 and ARM64 DLLs,
which Ubuntu's x86 binutils objdump cannot parse).

Prints machine type, optional-header magic, DLL flag, exported names and
imported DLL names. `--json` prints the same as JSON.
"""
import json
import struct
import sys

MACHINES = {0x8664: "x64 (IMAGE_FILE_MACHINE_AMD64)", 0xAA64: "ARM64 (IMAGE_FILE_MACHINE_ARM64)",
            0x014C: "x86 (IMAGE_FILE_MACHINE_I386)", 0xA641: "ARM64EC", 0x01C4: "ARMNT"}


def inspect(path):
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        raise SystemExit(f"{path}: not an MZ/PE file")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit(f"{path}: missing PE signature")
    machine, nsect, _, _, _, opt_size, characteristics = struct.unpack_from("<HHIIIHH", data, pe + 4)
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic == 0x20B:  # PE32+
        ndd_off, dd_off = opt + 108, opt + 112
    else:
        ndd_off, dd_off = opt + 92, opt + 96
    ndd = struct.unpack_from("<I", data, ndd_off)[0]
    dirs = [struct.unpack_from("<II", data, dd_off + 8 * i) for i in range(min(ndd, 16))]
    sect_off = opt + opt_size
    sections = []
    for i in range(nsect):
        name, vsize, va, rsize, rptr = struct.unpack_from("<8sIIII", data, sect_off + 40 * i)
        sections.append((name.rstrip(b"\0").decode(errors="replace"), va, max(vsize, rsize), rptr))

    def off(rva):
        for _, va, size, rptr in sections:
            if va <= rva < va + size:
                return rptr + (rva - va)
        raise ValueError(f"RVA {rva:#x} not in any section")

    def cstr(rva):
        o = off(rva)
        return data[o:data.index(b"\0", o)].decode()

    exports = []
    if len(dirs) > 0 and dirs[0][0]:
        e = off(dirs[0][0])
        nnames, _, names_rva = struct.unpack_from("<I", data, e + 24)[0], 0, struct.unpack_from("<I", data, e + 32)[0]
        for i in range(nnames):
            exports.append(cstr(struct.unpack_from("<I", data, off(names_rva) + 4 * i)[0]))
    imports = []
    if len(dirs) > 1 and dirs[1][0]:
        d = off(dirs[1][0])
        while True:
            ilt, _, _, name_rva, iat = struct.unpack_from("<IIIII", data, d)
            if ilt == 0 and name_rva == 0 and iat == 0:
                break
            imports.append(cstr(name_rva))
            d += 20
    return {
        "machine": MACHINES.get(machine, f"unknown ({machine:#06x})"),
        "machine_raw": f"{machine:#06x}",
        "optional_header_magic": f"{magic:#05x}" + (" (PE32+)" if magic == 0x20B else " (PE32)"),
        "is_dll": bool(characteristics & 0x2000),
        "exports": exports,
        "imports": imports,
    }


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--json"]
    info = inspect(args[0])
    if "--json" in sys.argv:
        print(json.dumps(info))
    else:
        for k in ("machine", "machine_raw", "optional_header_magic", "is_dll"):
            print(f"{k:22} = {info[k]}")
        print("exports:"); [print("  " + x) for x in info["exports"]]
        print("imports:"); [print("  " + x) for x in info["imports"]]
