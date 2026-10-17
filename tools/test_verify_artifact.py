#!/usr/bin/env python3
"""Tests for tools/verify_artifact.py (python3 -m unittest discover -s tools).

The verifier's job is to FAIL on a bad artifact, so most tests feed it something
wrong. A tiny fake `duckdb` CLI stands in for the real one; behaviour is chosen
with the FAKE_MODE environment variable. CI additionally runs the verifier
against the real stock CLI.
"""
import os
import stat
import subprocess
import sys
import shutil
import tempfile
import textwrap
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import package  # noqa: E402
import verify_artifact as va  # noqa: E402

REPO = os.path.dirname(HERE)
FOOTER_SCRIPT = os.path.join(REPO, "third_party", "extension-ci-tools", "append_extension_metadata.py")

FAKE_CLI = textwrap.dedent('''\
    #!/usr/bin/env python3
    import os, sys
    mode = os.environ.get("FAKE_MODE", "ok")
    args = sys.argv[1:]
    sql = args[args.index("-c") + 1] if "-c" in args else ""
    def out(s): sys.stdout.write(s + "\\n")
    if "pragma_version" in sql:
        out("v1.5.6,069cc9f9b5"); sys.exit(0)
    if "oracle_query" in sql:
        if mode == "no_error": out("1"); sys.exit(0)
        if mode == "error_exit0": out("Binder Error: connect failed: ORA-12541"); sys.exit(0)
        if mode == "crash": out("Binder Error: connect failed: ORA-12541"); sys.exit(139)
        if mode == "leaks_password": out("Binder Error: connect failed: ORA-12541 " + os.environ.get("ORACLE_PASSWORD", "")); sys.exit(1)
        out("Binder Error: duckdb_oracle: connect failed: ORA-12541: Cannot connect"); sys.exit(1)
    if "LOAD '" in sql:
        path = sql.split("LOAD '")[1].split("'")[0]
        base = os.path.basename(path)
        if mode == "load_fails":
            out("IO Error: could not load"); sys.exit(1)
        if base != "duckdb_oracle.duckdb_extension" and mode in ("misnamed_exit0", "misnamed_crash"):
            out('IO Error: File "%s" did not contain function "%s_init_c_api"' % (base, base.rsplit(".", 1)[0])); sys.exit(0 if mode == "misnamed_exit0" else 139)
        if base != "duckdb_oracle.duckdb_extension" and mode == "misnamed_other_error":
            out("IO Error: some unrelated failure"); sys.exit(1)
        if base != "duckdb_oracle.duckdb_extension" and mode != "misnamed_loads":
            out('IO Error: File "%s" did not contain function "%s_init_c_api"' % (base, base.rsplit(".", 1)[0])); sys.exit(1)
        if "SELECT loaded" in sql:
            out("false" if mode == "not_loaded" else "true"); sys.exit(0)
        out("client_library_found,message"); out("false,DPI-1047: no client"); sys.exit(0)
    if "duckdb_extensions()" in sql or "duckdb_functions()" in sql:
        out("1" if mode == "preloaded" else "0"); out("0"); sys.exit(0)
    sys.exit(0)
''')


def failed(findings):
    return [f.name for f in findings if not f.ok]


class Tmp(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.dir = self.td.name
        self.addCleanup(self.td.cleanup)

    def path(self, *p):
        return os.path.join(self.dir, *p)

    def make_zip(self, entries, name="a.zip"):
        z = self.path(name)
        with zipfile.ZipFile(z, "w") as f:
            for n, data in entries:
                f.writestr(n, data)
        return z

    def fake_cli(self, mode="ok"):
        p = self.path("duckdb")
        with open(p, "w") as f:
            f.write(FAKE_CLI)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
        return va.Cli([sys.executable, p], env={"FAKE_MODE": mode})


class ResolveTests(Tmp):
    def test_zip_with_exactly_the_shipped_name_is_extracted_unchanged(self):
        z = self.make_zip([(package.SHIPPED_NAME, b"payload")])
        with va.resolve(z) as r:
            self.assertEqual(os.path.basename(r.path), package.SHIPPED_NAME)
            self.assertEqual(open(r.path, "rb").read(), b"payload")
            extracted = r.path
        self.assertFalse(os.path.exists(extracted), "temporary extraction must be cleaned up")

    def test_zip_with_a_platform_suffixed_inner_name_is_refused(self):
        z = self.make_zip([("duckdb_oracle-linux_amd64.duckdb_extension", b"x")])
        with self.assertRaises(va.ArtifactError) as cm:
            va.resolve(z).__enter__()
        self.assertIn(package.SHIPPED_NAME, str(cm.exception))

    def test_zip_with_extra_entries_is_refused(self):
        z = self.make_zip([(package.SHIPPED_NAME, b"x"), ("README.txt", b"y")])
        with self.assertRaises(va.ArtifactError):
            va.resolve(z).__enter__()

    def test_zip_with_a_directory_prefix_is_refused(self):
        z = self.make_zip([("pkg/" + package.SHIPPED_NAME, b"x")])
        with self.assertRaises(va.ArtifactError):
            va.resolve(z).__enter__()

    def test_loose_file_must_already_have_the_shipped_name(self):
        good = self.path(package.SHIPPED_NAME)
        open(good, "wb").write(b"x")
        with va.resolve(good) as r:
            self.assertEqual(r.path, good)
        bad = self.path("duckdb_oracle-windows_amd64.duckdb_extension")
        open(bad, "wb").write(b"x")
        with self.assertRaises(va.ArtifactError) as cm:
            va.resolve(bad).__enter__()
        # tells the user what DuckDB would look for
        self.assertIn("duckdb_oracle-windows_amd64_init_c_api", str(cm.exception))

    def test_the_name_rule_has_one_source_of_truth(self):
        self.assertIs(va.SHIPPED_NAME, package.SHIPPED_NAME)


class MissingArtifactTests(Tmp):
    def test_a_missing_artifact_is_a_failed_check_not_a_traceback(self):
        for missing in (self.path("nope.zip"), self.path(package.SHIPPED_NAME)):
            r = subprocess.run([sys.executable, os.path.join(HERE, "verify_artifact.py"), "check", missing, "--platform", "linux_amd64"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertNotIn("Traceback", r.stderr)
            self.assertIn("FAIL", r.stdout)

    def test_extract_of_a_missing_artifact_fails_cleanly(self):
        r = subprocess.run([sys.executable, os.path.join(HERE, "verify_artifact.py"), "extract", self.path("nope.zip")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("Traceback", r.stderr)

    def test_a_file_that_is_not_a_zip_fails_cleanly(self):
        bad = self.path("bad.zip")
        open(bad, "wb").write(b"this is not a zip")
        with self.assertRaises(va.ArtifactError):
            va.resolve(bad).__enter__()


class FooterTests(Tmp):
    def build(self, platform, version):
        lib = self.path("lib.bin")
        open(lib, "wb").write(b"\0" * 1000)
        out = self.path(package.SHIPPED_NAME)
        subprocess.run([sys.executable, FOOTER_SCRIPT, "--extension-name", "duckdb_oracle", "--extension-version", "v0.0.0",
                        "--duckdb-platform", platform, "--duckdb-version", version, "--abi-type", "C_STRUCT",
                        "--library-file", lib, "--out-file", out], check=True, capture_output=True)
        return out

    def test_matching_footer_passes(self):
        f = self.build("linux_amd64", "v1.2.0")
        self.assertTrue(all(x.ok for x in va.check_footer(f, "linux_amd64", "v1.2.0")))

    def test_wrong_platform_or_version_fails(self):
        f = self.build("linux_amd64", "v1.2.0")
        self.assertFalse(all(x.ok for x in va.check_footer(f, "windows_amd64", "v1.2.0")))
        self.assertFalse(all(x.ok for x in va.check_footer(f, "linux_amd64", "v1.5.6")))

    def test_a_file_without_a_footer_fails_instead_of_raising(self):
        f = self.path(package.SHIPPED_NAME)
        open(f, "wb").write(b"\0" * 2000)
        self.assertFalse(all(x.ok for x in va.check_footer(f, "linux_amd64", "v1.2.0")))
        tiny = self.path("tiny")
        open(tiny, "wb").write(b"x")
        self.assertFalse(all(x.ok for x in va.check_footer(tiny, "linux_amd64", "v1.2.0")))


class PeTests(unittest.TestCase):
    DLL = os.environ.get("DUCKDB_ORACLE_WINDOWS_DLL")

    @unittest.skipUnless(DLL, "set DUCKDB_ORACLE_WINDOWS_DLL to a built windows_amd64 extension")
    def test_a_real_windows_amd64_extension_passes(self):
        self.assertTrue(all(x.ok for x in va.check_pe(self.DLL, "windows_amd64")), [str(x) for x in va.check_pe(self.DLL, "windows_amd64")])

    @unittest.skipUnless(DLL, "set DUCKDB_ORACLE_WINDOWS_DLL to a built windows_amd64 extension")
    def test_the_wrong_machine_type_is_caught(self):
        self.assertFalse(all(x.ok for x in va.check_pe(self.DLL, "windows_arm64")))

    def test_a_non_pe_file_fails_instead_of_raising(self):
        with tempfile.NamedTemporaryFile() as f:
            f.write(b"not a pe")
            f.flush()
            self.assertFalse(all(x.ok for x in va.check_pe(f.name, "windows_amd64")))


class LoadTests(Tmp):
    def ext(self):
        p = self.path(package.SHIPPED_NAME)
        open(p, "wb").write(b"x")
        return p

    def test_a_healthy_cli_passes_every_load_check(self):
        res = va.check_load(self.fake_cli("ok"), self.ext())
        self.assertTrue(all(x.ok for x in res), [str(x) for x in res])

    def test_an_already_present_extension_fails(self):
        self.assertEqual(failed(va.check_load(self.fake_cli("preloaded"), self.ext())), ["not built in or preinstalled"])

    def test_a_load_error_fails_the_load_check_itself(self):
        self.assertIn("LOAD exits 0", failed(va.check_load(self.fake_cli("load_fails"), self.ext())))

    def test_loaded_must_be_reported_true(self):
        self.assertEqual(failed(va.check_load(self.fake_cli("not_loaded"), self.ext())), ["duckdb_extensions() reports loaded = true"])

    def test_negative_control_passes_when_a_misnamed_copy_is_rejected(self):
        self.assertTrue(va.check_negative_control(self.fake_cli("ok"), self.ext(), "linux_amd64").ok)

    def test_negative_control_accepts_exit_0_from_old_clis_when_the_symbol_error_is_shown(self):
        self.assertTrue(va.check_negative_control(self.fake_cli("misnamed_exit0"), self.ext(), "linux_amd64").ok)

    def test_negative_control_fails_when_the_cli_crashes_while_loading_the_copy(self):
        self.assertFalse(va.check_negative_control(self.fake_cli("misnamed_crash"), self.ext(), "linux_amd64").ok)

    def test_negative_control_fails_if_a_misnamed_copy_would_load(self):
        self.assertFalse(va.check_negative_control(self.fake_cli("misnamed_loads"), self.ext(), "linux_amd64").ok)

    def test_negative_control_needs_the_RIGHT_failure(self):
        # failing for an unrelated reason does not show that the name rule is enforced
        self.assertFalse(va.check_negative_control(self.fake_cli("misnamed_other_error"), self.ext(), "linux_amd64").ok)


class ClientTests(Tmp):
    def ext(self):
        p = self.path(package.SHIPPED_NAME)
        open(p, "wb").write(b"x")
        return p

    def test_unreachable_dsn_must_be_a_clean_oracle_error(self):
        res = va.check_client(self.fake_cli("ok"), self.ext(), None)
        self.assertTrue(all(x.ok for x in res), [str(x) for x in res])

    def test_a_query_that_unexpectedly_succeeds_fails(self):
        self.assertEqual(len(failed(va.check_client(self.fake_cli("no_error"), self.ext(), None))), 1)

    def test_old_cli_releases_exit_0_on_errors_so_the_error_text_decides(self):
        # DuckDB 1.2.x CLIs exit 0 after a failed statement; the message is what matters
        res = va.check_client(self.fake_cli("error_exit0"), self.ext(), None)
        self.assertEqual(failed(res), [], [str(x) for x in res])

    def test_a_crash_exit_code_fails_even_with_an_oracle_error_text(self):
        # exit 139 = SIGSEGV: "never crash the process"
        self.assertEqual(len(failed(va.check_client(self.fake_cli("crash"), self.ext(), None))), 1)

    def test_an_error_that_echoes_the_password_fails(self):
        res = va.check_client(self.fake_cli("leaks_password"), self.ext(), None)
        self.assertFalse(all(x.ok for x in res))
        self.assertTrue(any("password" in x.name for x in res if not x.ok))


class HangTests(unittest.TestCase):
    def test_a_hung_cli_is_reported_as_a_timeout_not_waited_for_forever(self):
        cli = va.Cli([sys.executable, "-c", "import time; time.sleep(30)"], timeout=1)
        rc, text = cli.run("SELECT 1")
        self.assertEqual(rc, 124)
        self.assertIn("hang", text)


class PeMockedTests(unittest.TestCase):
    """The PE rules, driven with crafted inspector output (no DLL needed)."""
    GOOD = {"machine_raw": "0x8664", "optional_header_magic": "0x20b (PE32+)", "is_dll": True,
            "exports": ["duckdb_oracle_init_c_api"], "imports": ["KERNEL32.dll", "api-ms-win-crt-heap-l1-1-0.dll", "ntdll.dll"]}

    def check(self, **change):
        from unittest import mock
        info = {**self.GOOD, **change}
        with mock.patch.object(va.pe_inspect, "inspect", return_value=info):
            return failed(va.check_pe("x.dll", "windows_amd64"))

    def test_the_good_image_passes(self):
        self.assertEqual(self.check(), [])

    def test_an_extra_export_is_caught(self):
        self.assertEqual(self.check(exports=["duckdb_oracle_init_c_api", "dpiContext_create"]), ["PE exports exactly the init symbol"])

    def test_a_missing_init_symbol_is_caught(self):
        self.assertEqual(self.check(exports=[]), ["PE exports exactly the init symbol"])

    def test_a_non_system_import_is_caught(self):
        self.assertEqual(self.check(imports=["KERNEL32.dll", "libgcc_s_seh-1.dll"]), ["PE imports only system DLLs"])

    def test_a_pe32_or_non_dll_image_is_caught(self):
        self.assertEqual(self.check(optional_header_magic="0x10b (PE32)"), ["PE32+"])
        self.assertEqual(self.check(is_dll=False), ["PE is a DLL"])


class CliTests(Tmp):
    def test_wine_paths_are_converted_to_the_Z_drive(self):
        cli = va.Cli(["wine64", "duckdb.exe"], wine=True)
        self.assertEqual(cli.ext_arg("/tmp/x/duckdb_oracle.duckdb_extension"), "Z:/tmp/x/duckdb_oracle.duckdb_extension")
        self.assertEqual(va.Cli(["duckdb"]).ext_arg("/tmp/x"), "/tmp/x")

    def test_the_client_directory_is_supplied_the_way_each_host_loads_libraries(self):
        self.assertEqual(va.Cli(["duckdb"]).client_env("/opt/ic"), {"LD_LIBRARY_PATH": "/opt/ic"})
        self.assertEqual(va.Cli(["wine64", "duckdb.exe"], wine=True).client_env("/opt/ic"), {"WINEPATH": "Z:\\opt\\ic"})
        self.assertEqual(va.Cli(["duckdb.exe"], native_windows=True).client_env("C:\\ic"), {"PATH": "C:\\ic" + os.pathsep + os.environ.get("PATH", "")})

    def test_extract_subcommand_prints_the_shipped_path_and_fails_on_a_bad_artifact(self):
        z = self.make_zip([(package.SHIPPED_NAME, b"x")])
        r = subprocess.run([sys.executable, os.path.join(HERE, "verify_artifact.py"), "extract", z], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.strip().endswith(package.SHIPPED_NAME))
        # a calling shell script uses the file after this process has exited
        extracted = r.stdout.strip()
        self.assertTrue(os.path.exists(extracted), "extract must leave the file in place for the caller")
        self.assertEqual(open(extracted, "rb").read(), b"x")
        shutil.rmtree(os.path.dirname(extracted))
        bad = self.make_zip([("wrong.duckdb_extension", b"x")], name="bad.zip")
        r = subprocess.run([sys.executable, os.path.join(HERE, "verify_artifact.py"), "extract", bad], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
