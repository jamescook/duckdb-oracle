#!/usr/bin/env python3
"""Tests for tools/e2e_run.py, with a fake DuckDB CLI so they need neither DuckDB nor Oracle."""
import contextlib
import io
import os
import stat
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import e2e_run  # noqa: E402

# The fake CLI reads the SQL file it is given (-f FILE) and behaves according to markers in it.
FAKE = textwrap.dedent('''\
    #!/usr/bin/env python3
    import os, sys, time
    argv = sys.argv[1:]
    open(os.environ["FAKE_ARGV_LOG"], "a").write(" ".join(argv) + "\\n")
    sql = open(argv[argv.index("-f") + 1], encoding="utf-8").read()
    open(os.environ["FAKE_SQL_LOG"], "a").write(sql + "\\n----\\n")
    if "FAKE_HANG" in sql:
        time.sleep(60)
    if "FAKE_LEAK" in sql:
        print("connected with password " + os.environ.get("ORACLE_PASSWORD", ""))
    if "FAKE_FAIL" in sql:
        sys.stderr.write("Invalid Input Error: FAILED: the sum is wrong\\n")
        sys.exit(1)
    if "FAKE_ERROR" in sql:
        sys.stderr.write("Binder Error: ORA-00942: table or view does not exist\\n")
        sys.exit(1)
    if "FAKE_WAITDB" in sql:
        counter = os.environ["FAKE_COUNTER"]
        n = int(open(counter).read() or 0) if os.path.exists(counter) else 0
        open(counter, "w").write(str(n + 1))
        if n < int(os.environ.get("FAKE_FAIL_FIRST", "0")):
            sys.stderr.write("IO Error: ORA-12541: TNS:no listener\\n")
            sys.exit(1)
    if "SELECT 1 FROM dual" in sql:
        counter = os.environ.get("FAKE_COUNTER")
        if counter:
            n = int(open(counter).read() or 0) if os.path.exists(counter) else 0
            open(counter, "w").write(str(n + 1))
            if n < int(os.environ.get("FAKE_FAIL_FIRST", "0")):
                sys.stderr.write("IO Error: ORA-12541: TNS:no listener\\n")
                sys.exit(1)
    print("PASS: 3 checks")
''')


def slurp(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.duckdb = os.path.join(t, "duckdb")
        with open(self.duckdb, "w") as f:
            f.write(FAKE)
        os.chmod(self.duckdb, os.stat(self.duckdb).st_mode | stat.S_IXUSR)
        self.ext = os.path.join(t, "duckdb_oracle.duckdb_extension")
        open(self.ext, "w").close()
        self.dir = os.path.join(t, "tests")
        os.mkdir(self.dir)
        self.argv_log = os.path.join(t, "argv.log")
        self.sql_log = os.path.join(t, "sql.log")
        self.counter = os.path.join(t, "counter")
        self.env = {"ORACLE_USER": "e2e", "ORACLE_PASSWORD": "s3cret-Pw!", "FAKE_ARGV_LOG": self.argv_log,
                    "FAKE_SQL_LOG": self.sql_log, "FAKE_COUNTER": self.counter}
        old = dict(os.environ)
        os.environ.update(self.env)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))

    def write(self, name, text):
        with open(os.path.join(self.dir, name), "w", encoding="utf-8") as f:
            f.write(text)

    def run_main(self, *extra, dsn="db.example:1521/PDB1"):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = e2e_run.main(["--duckdb", self.duckdb, "--extension", self.ext, "--dsn", dsn, *extra, self.dir])
        return code, out.getvalue(), err.getvalue()


class Directives(unittest.TestCase):
    def test_header_directives(self):
        d = e2e_run.read_directives("-- e2e: Title here\n-- expect-error: ORA-00942\n-- expect-error: second\n"
                                    "-- expect-output: still-running\n-- timeout: 90\n-- optional\n\nSELECT 1;\n")
        self.assertEqual(d.title, "Title here")
        self.assertEqual(d.expect_error, ["ORA-00942", "second"])
        self.assertEqual(d.expect_output, ["still-running"])
        self.assertEqual(d.timeout, 90)
        self.assertTrue(d.optional)

    def test_directives_stop_at_the_first_sql_line(self):
        d = e2e_run.read_directives("-- e2e: T\nSELECT 1;\n-- optional\n-- expect-error: x\n")
        self.assertFalse(d.optional)
        self.assertEqual(d.expect_error, [])

    def test_plain_comments_and_blank_lines_in_the_header_are_ignored(self):
        d = e2e_run.read_directives("-- e2e: T\n-- (an explanation)\n\n--optional\n-- timeout: 5\n")
        self.assertTrue(d.optional)
        self.assertEqual(d.timeout, 5)

    def test_crlf(self):
        d = e2e_run.read_directives("-- e2e: T\r\n-- timeout: 7\r\nSELECT 1;\r\n")
        self.assertEqual((d.title, d.timeout), ("T", 7))


class Judging(unittest.TestCase):
    def d(self, **kw):
        d = e2e_run.Directives()
        d.__dict__.update(kw)
        return d

    def r(self, code=0, out="", err="", timed_out=False):
        return e2e_run.Result(code, out, err, timed_out)

    def test_exit_zero_passes_and_nonzero_fails(self):
        self.assertEqual(e2e_run.judge(self.d(), self.r(0), {}), [])
        self.assertIn("exit code 1", e2e_run.judge(self.d(), self.r(1), {})[0])

    def test_expect_error_needs_exit_one_and_matching_text(self):
        d = self.d(expect_error=["ORA-00942"])
        self.assertEqual(e2e_run.judge(d, self.r(1, err="Error: ora-00942: x"), {}), [])  # case-insensitive
        self.assertIn("expected a DuckDB error", e2e_run.judge(d, self.r(0, out="ORA-00942"), {})[0])
        self.assertIn("does not match", e2e_run.judge(d, self.r(1, err="something else"), {})[0])

    def test_expect_output_is_checked_in_either_stream(self):
        d = self.d(expect_output=["still-running"])
        self.assertEqual(e2e_run.judge(d, self.r(0, out="x still-running y"), {}), [])
        self.assertTrue(e2e_run.judge(d, self.r(0, out="nothing"), {}))

    def test_timeout_is_a_problem_whatever_the_code(self):
        self.assertEqual(e2e_run.judge(self.d(), self.r(-1, timed_out=True), {})[0], "TIMEOUT (hang)")

    def test_the_password_in_output_is_a_problem_and_is_redacted(self):
        env = {"ORACLE_PASSWORD": "hunter2-xyz"}
        self.assertTrue(any("PASSWORD" in p for p in e2e_run.judge(self.d(), self.r(0, out="pw=hunter2-xyz"), env)))
        self.assertEqual(e2e_run.hide_secrets("pw=hunter2-xyz!", env), "pw=***!")

    def test_a_short_password_is_not_treated_as_a_secret(self):
        # three characters would redact half of every log; the rule needs at least four
        self.assertEqual(e2e_run.secrets({"ORACLE_PASSWORD": "abc"}), [])


class Runner(Case):
    def test_every_verdict_and_the_exit_code(self):
        self.write("01_ok.sql", "-- e2e: fine\nSELECT 1;\n")
        self.write("02_fail.sql", "-- e2e: wrong sum\n-- FAKE_FAIL\nSELECT 1;\n")
        self.write("03_expected_error.sql", "-- e2e: errors\n-- expect-error: ORA-00942\n-- FAKE_ERROR\nSELECT 1;\n")
        self.write("04_expected_error_but_ok.sql", "-- e2e: should have errored\n-- expect-error: ORA-00942\nSELECT 1;\n")
        self.write("05_optional.sql", "-- e2e: probe\n-- optional\n-- FAKE_FAIL\nSELECT 1;\n")
        code, out, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("PASS  tests/01_ok", out)
        self.assertIn("FAIL  tests/02_fail: exit code 1; Invalid Input Error: FAILED: the sum is wrong", out)
        self.assertIn("PASS  tests/03_expected_error", out)
        self.assertIn("FAIL  tests/04_expected_error_but_ok: expected a DuckDB error", out)
        self.assertIn("WARN  tests/05_optional", out)
        self.assertIn("2 passed, 1 warnings, 2 failed", out)

    def test_only_passes_and_warnings_exit_zero(self):
        self.write("01_ok.sql", "-- e2e: fine\nSELECT 1;\n")
        self.write("02_optional.sql", "-- optional\n-- FAKE_FAIL\nSELECT 1;\n")
        code, out, _ = self.run_main()
        self.assertEqual(code, 0, out)

    def test_dsn_is_substituted_with_quotes_doubled_and_the_extension_is_loaded_first(self):
        self.write("01.sql", "-- e2e: dsn\nSELECT '@DSN@';\n")
        self.run_main(dsn="host:1521/it's")
        sql = slurp(self.sql_log)
        self.assertTrue(sql.startswith(f"LOAD '{self.ext}';\n"))
        self.assertIn("SELECT 'host:1521/it''s';", sql)
        self.assertNotIn("@DSN@", sql)

    def test_the_password_never_reaches_a_command_line_or_a_sql_file(self):
        self.write("01.sql", "-- e2e: x\nSELECT 1;\n")
        self.run_main()
        self.assertNotIn("s3cret-Pw!", slurp(self.argv_log))
        self.assertNotIn("s3cret-Pw!", slurp(self.sql_log))
        self.assertIn("-unsigned -bail -f ", slurp(self.argv_log))

    def test_a_leaked_password_fails_the_file_and_is_redacted_in_the_log(self):
        self.write("01_leak.sql", "-- e2e: leaks\n-- FAKE_LEAK\nSELECT 1;\n")
        code, out, err = self.run_main()
        self.assertEqual(code, 1)
        self.assertNotIn("s3cret-Pw!", out + err)
        self.assertIn("connected with password ***", out)
        self.assertIn("THE PASSWORD APPEARED", out)

    def test_a_hanging_file_is_killed_at_its_own_timeout(self):
        self.write("01_hang.sql", "-- e2e: hangs\n-- timeout: 1\n-- FAKE_HANG\nSELECT 1;\n")
        code, out, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("TIMEOUT (hang)", out)

    def test_directories_run_in_the_order_given_and_files_sorted_by_name(self):
        other = os.path.join(self.tmp.name, "second")
        os.mkdir(other)
        self.write("b.sql", "-- e2e: b\nSELECT 1;\n")
        self.write("a.sql", "-- e2e: a\nSELECT 1;\n")
        with open(os.path.join(other, "z.sql"), "w") as f:
            f.write("-- e2e: z\nSELECT 1;\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            e2e_run.main(["--duckdb", self.duckdb, "--extension", self.ext, "--dsn", "d", other, self.dir])
        order = [l.split()[1] for l in out.getvalue().splitlines() if l.startswith("PASS ")]
        self.assertEqual(order, ["second/z:", "tests/a:", "tests/b:"])

    def test_an_empty_directory_is_a_failure_not_a_silent_pass(self):
        code, out, _ = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("no .sql files", out)

    def test_usage_problems_exit_two(self):
        del os.environ["ORACLE_PASSWORD"]
        code, _, err = self.run_main()
        self.assertEqual(code, 2)
        self.assertIn("ORACLE_PASSWORD is not set", err)
        os.environ["ORACLE_PASSWORD"] = "s3cret-Pw!"
        bad = os.path.join(self.tmp.name, "renamed.duckdb_extension")
        open(bad, "w").close()
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = e2e_run.main(["--duckdb", self.duckdb, "--extension", bad, "--dsn", "d", self.dir])
        self.assertEqual(code, 2)
        self.assertIn("shipped name", err.getvalue())


class Waiting(Case):
    def test_waits_until_the_database_answers(self):
        self.write("01.sql", "-- e2e: x\nSELECT 1;\n")
        os.environ["FAKE_FAIL_FIRST"] = "2"
        self.addCleanup(lambda: os.environ.pop("FAKE_FAIL_FIRST", None))
        code, out, _ = self.run_main("--wait", "30", "--retry", "0")
        self.assertEqual(code, 0, out)
        self.assertIn("not ready yet", out)
        self.assertIn("Database is ready (attempt 3)", out)
        self.assertIn("PASS  database ready", out)

    def test_gives_up_with_a_failure_and_runs_no_test(self):
        self.write("01.sql", "-- e2e: x\nSELECT 1;\n")
        os.environ["FAKE_FAIL_FIRST"] = "1000"
        self.addCleanup(lambda: os.environ.pop("FAKE_FAIL_FIRST", None))
        code, out, err = self.run_main("--wait", "1", "--retry", "0")
        self.assertEqual(code, 1)
        self.assertIn("FAIL  database ready", out)
        self.assertNotIn("tests/01", out)
        self.assertIn("did not become ready", err)


if __name__ == "__main__":
    unittest.main()
