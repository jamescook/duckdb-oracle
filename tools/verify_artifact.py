#!/usr/bin/env python3
"""Verify a built duckdb-oracle artifact: the one place that knows the rules.

The rules (what a shippable artifact is, what must load, what must fail) used to
be re-implemented in bash, PowerShell and CI YAML, so every change to them (the
v0.6.1 zip/rename change touched eight files) was shotgun surgery. They live
here now; CI, developers and the Windows-under-Wine runs all call this.

Subcommands
  extract <artifact>
      Print the path of the extension exactly as shipped, extracted into a
      temporary directory that is removed when the process exits. <artifact> is
      duckdb_oracle-<platform>.zip (must contain exactly duckdb_oracle.duckdb_extension)
      or a loose file that already has that name. Nothing is ever renamed: a
      wrongly named artifact fails, because DuckDB derives <name>_init_c_api
      from the file name.
  check <artifact> --platform P [--capi-version V] [--duckdb CLI [--wine CMD]]
        [--client DIR|none ...]
      The name rule, the metadata footer, for Windows platforms the PE image
      (machine, exports, imports), and, given a DuckDB CLI, loading into the stock
      CLI (not preloaded, LOAD exits 0, loaded = true) plus a negative control (a
      platform-suffixed copy must NOT load). Each --client runs the "client
      present or absent" checks: oracle_client_info() works, and an unreachable
      DSN is a clean ORA-/DPI- error that does not echo the password.

Exit code 0 only if every check passed.
"""
import argparse
import contextlib
import dataclasses
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_footer as footer_lib  # noqa: E402
import package  # noqa: E402
import pe_inspect  # noqa: E402

# The producer (package.py) owns the name; this module only consumes it.
SHIPPED_NAME = package.SHIPPED_NAME
EXTENSION_NAME = SHIPPED_NAME.split(".")[0]

# the distinctive secret used to prove that errors never echo a password
PROBE_PASSWORD = "verify-secret-9f3a"


class ArtifactError(Exception):
    pass


@dataclasses.dataclass
class Finding:
    name: str
    ok: bool
    detail: str = ""

    def __str__(self):
        return ("PASS  " if self.ok else "FAIL  ") + self.name + (f": {self.detail}" if self.detail and not self.ok else "")


# ---------------------------------------------------------------------------
# The shipped name rule
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class Resolved:
    path: str


def _require_shipped_entry(z, src):
    """The zip rule, in one place: exactly one entry, with the shipped name."""
    names = z.namelist()
    if names != [SHIPPED_NAME]:
        raise ArtifactError(f"{src} must contain exactly [{SHIPPED_NAME}], found {names}")


@contextlib.contextmanager
def resolve(src):
    """Yield the extension exactly as shipped (see module doc)."""
    if src.lower().endswith(".zip"):
        with zipfile.ZipFile(src) as z:
            _require_shipped_entry(z, src)
            tmp = tempfile.mkdtemp(prefix="duckdb-oracle-pkg.")
            try:
                z.extract(SHIPPED_NAME, tmp)
                yield Resolved(os.path.join(tmp, SHIPPED_NAME))
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
    else:
        base = os.path.basename(src)
        if base != SHIPPED_NAME:
            raise ArtifactError(
                f"'{src}' is not named {SHIPPED_NAME}; DuckDB would look for "
                f"'{base.rsplit('.', 1)[0]}_init_c_api' and fail to load it")
        yield Resolved(src)


def extract(src):
    """Path of the extension as shipped, left on disk for the caller to use and clean up.
    A zip is extracted into a fresh temporary directory (the caller removes it); a loose
    file is returned as is. Same rules as resolve()."""
    if not src.lower().endswith(".zip"):
        with resolve(src) as r:
            return r.path
    with zipfile.ZipFile(src) as z:
        _require_shipped_entry(z, src)
        tmp = tempfile.mkdtemp(prefix="duckdb-oracle-pkg.")
        z.extract(SHIPPED_NAME, tmp)
        return os.path.join(tmp, SHIPPED_NAME)


# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

def check_footer(path, platform, version, abi="C_STRUCT"):
    try:
        m = footer_lib.parse(path)
    except (SystemExit, OSError) as e:
        return [Finding("footer present", False, str(e))]
    out = [
        Finding("footer signature and magic", m["start_signature_ok"] and m["magic"] == "4", str(m)),
        Finding(f"footer abi type {abi}", m["abi_type"] == abi, m["abi_type"]),
        Finding(f"footer platform {platform}", m["platform"] == platform, m["platform"]),
    ]
    if version:
        out.append(Finding(f"footer C API version {version}", m["duckdb_version"] == version, m["duckdb_version"]))
    return out



_SYSTEM_DLL = re.compile(r"(?i)(kernel32|ntdll|api-ms-win-crt-[a-z0-9-]+)\.dll")
_MACHINES = {"windows_amd64": "0x8664", "windows_arm64": "0xaa64"}


def check_pe(path, platform):
    want = _MACHINES.get(platform)
    if want is None:
        return [Finding("PE platform", False, f"not a Windows platform: {platform}")]
    try:
        info = pe_inspect.inspect(path)
    except (SystemExit, Exception) as e:  # noqa: BLE001 - any parse failure is a failed check
        return [Finding("PE image", False, str(e))]
    return [
        Finding(f"PE machine {want}", info["machine_raw"].lower() == want, info["machine_raw"]),
        Finding("PE32+", info["optional_header_magic"].startswith("0x20b"), info["optional_header_magic"]),
        Finding("PE is a DLL", info["is_dll"]),
        Finding("PE exports exactly the init symbol", info["exports"] == [f"{EXTENSION_NAME}_init_c_api"], str(info["exports"])),
        Finding("PE imports only system DLLs", all(_SYSTEM_DLL.fullmatch(i) for i in info["imports"]), str(info["imports"])),
    ]


# ---------------------------------------------------------------------------
# Running a DuckDB CLI
# ---------------------------------------------------------------------------

class Cli:
    """A DuckDB command line: native, or the Windows exe under Wine."""

    def __init__(self, argv, env=None, wine=False, native_windows=False, timeout=120):
        self.argv = list(argv)
        self.native_windows = native_windows
        self.env = dict(env or {})
        self.wine = wine
        self.timeout = timeout

    def ext_arg(self, path):
        """The extension path as the CLI must be told it (Wine sees the host as Z:)."""
        return "Z:" + path if self.wine and path.startswith("/") else path

    def client_env(self, client_dir):
        """Environment that puts an Oracle client directory where this host's loader looks."""
        if self.wine:
            return {"WINEPATH": "Z:" + client_dir.replace("/", "\\")}
        if self.native_windows:
            return {"PATH": client_dir + os.pathsep + os.environ.get("PATH", "")}
        return {"LD_LIBRARY_PATH": client_dir}

    def run(self, sql, unsigned=True, csv=False, extra_env=None, drop_env=()):
        cmd = self.argv + (["-unsigned"] if unsigned else []) + (["-csv", "-noheader"] if csv else []) + ["-c", sql]
        env = dict(os.environ)
        env.update(self.env)
        env.update(extra_env or {})
        for k in drop_env:
            env.pop(k, None)
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=self.timeout)
            return p.returncode, (p.stdout + p.stderr).replace("\r", "")
        except subprocess.TimeoutExpired:
            return 124, f"timed out after {self.timeout}s (a hang)"


def check_load(cli, ext_path):
    out = []
    rc, text = cli.run("SELECT version() AS version, source_id FROM pragma_version();", unsigned=False)
    out.append(Finding("the DuckDB CLI runs", rc == 0, text))
    if rc != 0:
        return out

    rc, text = cli.run(
        f"SELECT count(*) FROM duckdb_extensions() WHERE extension_name='{EXTENSION_NAME}' AND (loaded OR installed); "
        "SELECT count(*) FROM duckdb_functions() WHERE function_name LIKE 'oracle_%';", unsigned=False, csv=True)
    counts = text.split()
    out.append(Finding("not built in or preinstalled", rc == 0 and counts[:2] == ["0", "0"], text))

    ext = cli.ext_arg(ext_path)
    rc, text = cli.run(f"LOAD '{ext}'; SELECT * FROM duckdb_extensions() WHERE extension_name='{EXTENSION_NAME}'; SELECT * FROM oracle_client_info();")
    out.append(Finding("LOAD exits 0", rc == 0, f"exit {rc}: {text.strip()[:400]}"))

    rc, text = cli.run(f"LOAD '{ext}'; SELECT loaded FROM duckdb_extensions() WHERE extension_name='{EXTENSION_NAME}';", csv=True)
    out.append(Finding("duckdb_extensions() reports loaded = true", rc == 0 and text.strip().splitlines()[-1:] == ["true"], text.strip()))
    return out


def check_negative_control(cli, ext_path, platform):
    """A platform-suffixed copy must NOT load (the bug the zip packaging guards against)."""
    with tempfile.TemporaryDirectory(prefix="duckdb-oracle-neg.") as d:
        bad = os.path.join(d, f"{EXTENSION_NAME}-{platform}.duckdb_extension")
        shutil.copyfile(ext_path, bad)
        rc, text = cli.run(f"LOAD '{cli.ext_arg(bad)}';")
    want = f"{EXTENSION_NAME}-{platform}_init_c_api"
    return Finding("negative control: a platform-suffixed copy must fail to load", rc != 0 and want in text,
                   f"exit {rc}, expected '{want}' in: {text.strip()[:300]}")


def check_client(cli, ext_path, client_dir):
    """With (client_dir) or without (None) an Oracle client on the library path."""
    env_drop = ("LD_LIBRARY_PATH",) if client_dir is None else ()
    extra = {} if client_dir is None else cli.client_env(client_dir)
    label = "no client" if client_dir is None else os.path.basename(client_dir.rstrip("/\\"))
    ext = cli.ext_arg(ext_path)
    out = []

    rc, text = cli.run(f"LOAD '{ext}'; SELECT client_library_found, message FROM oracle_client_info();", extra_env=extra, drop_env=env_drop)
    out.append(Finding(f"[{label}] oracle_client_info() works", rc == 0, text.strip()[:300]))

    creds = {"ORACLE_USER": "scott", "ORACLE_PASSWORD": PROBE_PASSWORD}
    rc, text = cli.run(f"LOAD '{ext}'; SELECT * FROM oracle_query('127.0.0.1:1/NOPE', 'SELECT * FROM dual');",
                       extra_env={**extra, **creds}, drop_env=env_drop)
    out.append(Finding(f"[{label}] an unreachable DSN is a clean ORA-/DPI- error (exit 1, no crash)",
                       rc == 1 and re.search(r"(ORA|DPI)-\d+", text) is not None, f"exit {rc}: {text.strip()[:300]}"))
    out.append(Finding(f"[{label}] the error does not echo the password", PROBE_PASSWORD not in text))
    return out


def run_all(src, platform, capi_version, cli, clients):
    findings = []
    try:
        with resolve(src) as r:
            findings.append(Finding(f"shipped as {SHIPPED_NAME}", True))
            findings += check_footer(r.path, platform, capi_version)
            if platform.startswith("windows"):
                findings += check_pe(r.path, platform)
            if cli is not None:
                findings += check_load(cli, r.path)
                findings.append(check_negative_control(cli, r.path, platform))
                for ic in clients:
                    findings += check_client(cli, r.path, None if ic == "none" else ic)
    except ArtifactError as e:
        findings.append(Finding(f"shipped as {SHIPPED_NAME}", False, str(e)))
    return findings


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("extract")
    ex.add_argument("artifact")
    ck = sub.add_parser("check")
    ck.add_argument("artifact")
    ck.add_argument("--platform", required=True)
    ck.add_argument("--capi-version", default="v1.2.0")
    ck.add_argument("--duckdb", help="stock DuckDB CLI to load the extension into")
    ck.add_argument("--wine", help="run --duckdb under this Wine command (Windows exe on a Linux host)")
    ck.add_argument("--client", action="append", default=[], help="Instant Client directory, or 'none'; repeatable")
    args = ap.parse_args(argv)

    if args.cmd == "extract":
        # Unlike check(), the caller (a shell script) uses the file after this process
        # exits, so it is left in place; the caller removes the directory when done.
        try:
            print(extract(args.artifact))
        except ArtifactError as e:
            print(f"FAIL: {e}", file=sys.stderr)
            return 1
        return 0

    cli = None
    if args.duckdb:
        cli = Cli(([args.wine] if args.wine else []) + [args.duckdb], wine=bool(args.wine), native_windows=(os.name == "nt"))
    findings = run_all(args.artifact, args.platform, args.capi_version, cli, args.client)
    for f in findings:
        print(f)
    failed = [f for f in findings if not f.ok]
    print("PASS" if not failed else f"FAIL: {len(failed)} of {len(findings)} checks")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
