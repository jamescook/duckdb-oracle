#!/usr/bin/env python3
"""Tests for tools/e2e-setup.sh with a fake sqlplus."""
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "e2e-setup.sh")

# Reads the password from stdin like sqlplus does, logs argv and the script it was asked to run.
FAKE = textwrap.dedent("""\
    #!/usr/bin/env bash
    read -r pw
    echo "$*" >> "$FAKE_ARGV_LOG"
    echo "PW:$pw" >> "$FAKE_PW_LOG"
    script="${@: -1}"; script="${script#@}"
    if grep -q "SELECT 1 FROM dual" "$script"; then
      n=$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_COUNTER"
      [ "$n" -lt "${FAKE_FAIL_FIRST:-0}" ] && { echo "ORA-12514: no service" >&2; exit 1; }
      exit 0
    fi
    echo "$script" >> "$FAKE_RAN_LOG"
    grep -q FAKE_FAIL "$script" && exit 3
    exit 0
""")


def slurp(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


class Setup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        self.sqlplus = os.path.join(t, "sqlplus")
        with open(self.sqlplus, "w") as f:
            f.write(FAKE)
        os.chmod(self.sqlplus, os.stat(self.sqlplus).st_mode | stat.S_IXUSR)
        self.logs = {k: os.path.join(t, k + ".log") for k in ("argv", "pw", "ran")}
        self.env = dict(os.environ, SQLPLUS=self.sqlplus, E2E_SETUP_PASSWORD="Setup-Pw-123", E2E_SETUP_RETRY="0",
                        E2E_SETUP_WAIT="5", FAKE_ARGV_LOG=self.logs["argv"], FAKE_PW_LOG=self.logs["pw"],
                        FAKE_RAN_LOG=self.logs["ran"], FAKE_COUNTER=os.path.join(t, "counter"))

    def dirs(self, **files):
        out = []
        for d, names in files.items():
            p = os.path.join(self.tmp.name, d)
            os.mkdir(p)
            for n, text in names.items():
                with open(os.path.join(p, n), "w") as f:
                    f.write(text)
            out.append(p)
        return out

    def run_script(self, dirs, env=None, dsn="localhost:1521/PDB1"):
        return subprocess.run([SCRIPT, dsn, *dirs], env=env or self.env, capture_output=True, text=True, timeout=60)

    def test_runs_every_script_in_order_and_directories_in_the_order_given(self):
        a, b = self.dirs(common={"02_b.sql": "x", "01_a.sql": "x"}, ai={"00_v.sql": "x"})
        r = self.run_script([a, b])
        self.assertEqual(r.returncode, 0, r.stderr)
        ran = [os.path.basename(p) for p in slurp(self.logs["ran"]).split()]
        self.assertEqual(ran, ["01_a.sql", "02_b.sql", "00_v.sql"])
        self.assertIn("e2e-setup: done", r.stdout)

    def test_the_password_goes_to_stdin_never_to_the_command_line(self):
        (d,) = self.dirs(common={"01.sql": "x"})
        self.run_script([d])
        self.assertNotIn("Setup-Pw-123", slurp(self.logs["argv"]))
        self.assertIn("PW:Setup-Pw-123", slurp(self.logs["pw"]))
        self.assertIn("-L -S system@//localhost:1521/PDB1", slurp(self.logs["argv"]))

    def test_a_failing_script_stops_the_run_with_its_exit_code(self):
        (d,) = self.dirs(common={"01_ok.sql": "x", "02_bad.sql": "FAKE_FAIL", "03_never.sql": "x"})
        r = self.run_script([d])
        self.assertEqual(r.returncode, 3)
        self.assertIn("02_bad.sql failed", r.stderr)
        ran = [os.path.basename(p) for p in slurp(self.logs["ran"]).split()]
        self.assertEqual(ran, ["01_ok.sql", "02_bad.sql"])

    def test_waits_for_the_login_to_work(self):
        (d,) = self.dirs(common={"01.sql": "x"})
        env = dict(self.env, FAKE_FAIL_FIRST="3")
        r = self.run_script([d], env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr.count("waiting for"), 3)

    def test_gives_up_when_the_database_never_answers(self):
        (d,) = self.dirs(common={"01.sql": "x"})
        env = dict(self.env, FAKE_FAIL_FIRST="100000", E2E_SETUP_WAIT="0")
        r = self.run_script([d], env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("no login to localhost:1521/PDB1", r.stderr)
        self.assertEqual(slurp(self.logs["ran"]), "")

    def test_usage_problems_exit_two_and_a_missing_password_is_named(self):
        (d,) = self.dirs(common={"01.sql": "x"})
        env = {k: v for k, v in self.env.items() if k != "E2E_SETUP_PASSWORD"}
        r = self.run_script([d], env)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("E2E_SETUP_PASSWORD", r.stderr)
        r = self.run_script([os.path.join(self.tmp.name, "nope")])
        self.assertEqual(r.returncode, 2)
        (empty,) = self.dirs(empty={})
        self.assertEqual(self.run_script([empty]).returncode, 2)


if __name__ == "__main__":
    unittest.main()
