#!/usr/bin/env python3
"""Run the end-to-end SQL tests (test/e2e/**) against a real Oracle database with the stock DuckDB CLI.

This is the Linux counterpart of the e2e part of test-windows.ps1 and judges every file by the same rules, so a
test file means the same thing wherever it runs (hosted CI on Linux, the self-hosted Windows runner, a laptop).

    tools/e2e_run.py --duckdb ./duckdb --extension ./duckdb_oracle.duckdb_extension \\
        --dsn localhost:1521/FREEPDB1 [--wait 300] [--timeout 180] test/e2e test/e2e/spatial ...

The login comes from the environment (ORACLE_USER, ORACLE_PASSWORD) and is handed to the DuckDB process only
through its environment: never on a command line, never in a SQL file. A password that shows up in any output
fails the file and is redacted before anything is printed.

File conventions (the header is the leading block of `--` lines):
    -- e2e: <title>              shown in the report
    -- expect-error: <regex>     the file must end with a DuckDB error (exit code 1) and the output must match
    -- expect-output: <regex>    the output must match (may repeat)
    -- timeout: <seconds>        per-file limit, default --timeout
    -- optional                  a failing file is a WARNING, not a failure
    @DSN@ in the text is replaced by the connect string.
Without expect-error the file must exit 0; a failed check calls error('FAILED: ...') and so fails the run.

Exit code: 0 if no file failed, 1 otherwise (2 for a usage or setup problem).
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

REDACT = "***"
SECRET_ENV = ("ORACLE_PASSWORD", "ORACLE_PASSWORD_23AI")


class Directives:
    def __init__(self):
        self.title = ""
        self.expect_error = []
        self.expect_output = []
        self.timeout = 0
        self.optional = False


def read_directives(text):
    d = Directives()
    for line in re.split(r"\r?\n", text):
        t = line.strip()
        if t == "":
            continue
        if not t.startswith("--"):
            break
        m = re.match(r"^--\s*e2e:\s*(.+)$", t)
        if m:
            d.title = m.group(1).strip()
            continue
        m = re.match(r"^--\s*expect-error:\s*(.+)$", t)
        if m:
            d.expect_error.append(m.group(1).strip())
            continue
        m = re.match(r"^--\s*expect-output:\s*(.+)$", t)
        if m:
            d.expect_output.append(m.group(1).strip())
            continue
        m = re.match(r"^--\s*timeout:\s*(\d+)\s*$", t)
        if m:
            d.timeout = int(m.group(1))
            continue
        if re.match(r"^--\s*optional\s*$", t):
            d.optional = True
    return d


def secrets(env):
    return [v for k in SECRET_ENV for v in [env.get(k)] if v and len(v) >= 4]


def has_secret(text, env):
    return any(s in text for s in secrets(env))


def hide_secrets(text, env):
    for s in secrets(env):
        text = text.replace(s, REDACT)
    return text


def sql_literal(text):
    return "'" + text.replace("'", "''") + "'"


class Result:
    def __init__(self, code, out, err, timed_out):
        self.code, self.out, self.err, self.timed_out = code, out, err, timed_out


def run_duckdb(duckdb, sql, timeout, env):
    """Run the CLI on a SQL file (never SQL on the command line), killing it after `timeout` seconds."""
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False, encoding="utf-8") as f:
        f.write(sql)
        path = f.name
    try:
        p = subprocess.Popen([duckdb, "-unsigned", "-bail", "-f", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, encoding="utf-8", errors="replace", env=env)
        try:
            out, err = p.communicate(timeout=timeout)
            return Result(p.returncode, out, err, False)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            return Result(-1, out or "", err or "", True)
    finally:
        os.unlink(path)


def judge(d, r, env):
    """The problems with one file's run; an empty list is a pass."""
    problems = []
    combined = r.out + "\n" + r.err
    if r.timed_out:
        problems.append("TIMEOUT (hang)")
    elif d.expect_error:
        if r.code != 1:
            problems.append(f"expected a DuckDB error (exit code 1), got exit code {r.code}")
    elif r.code != 0:
        problems.append(f"exit code {r.code}")
    for rx in d.expect_error + d.expect_output:
        if not re.search(rx, combined, re.IGNORECASE):
            problems.append(f"output does not match /{rx}/")
    if has_secret(combined, env):
        problems.append("THE PASSWORD APPEARED IN THE OUTPUT (it is redacted in this log)")
    return problems


def failed_checks(r):
    return [l.strip() for l in re.split(r"\r?\n", r.err) if "FAILED:" in l]


def run_file(path, group, args, env, report):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    d = read_directives(text)
    base = os.path.splitext(os.path.basename(path))[0]
    name = f"{group}/{base}"
    print(f"\n=== e2e {name}: {d.title or base}", flush=True)
    sql = f"LOAD {sql_literal(args.extension)};\n" + text.replace("@DSN@", args.dsn.replace("'", "''"))
    r = run_duckdb(args.duckdb, sql, d.timeout or args.timeout, env)
    for stream in (r.out, r.err):
        shown = hide_secrets(stream, env).rstrip()
        if shown:
            print(shown, flush=True)
    problems = judge(d, r, env)
    if not problems:
        status, detail = "PASS", f"exit code {r.code}"
    else:
        status = "WARN" if d.optional else "FAIL"
        detail = "; ".join(problems + failed_checks(r))
    print(f"--- {status}: {name}: {hide_secrets(detail, env)}", flush=True)
    report.append((status, name, hide_secrets(detail, env)))


def wait_for_database(args, env):
    """Poll oracle_query('SELECT 1 FROM dual') until it answers or `args.wait` seconds have passed."""
    sql = f"LOAD {sql_literal(args.extension)};\nSELECT * FROM oracle_query({sql_literal(args.dsn)}, 'SELECT 1 FROM dual');\n"
    deadline = time.monotonic() + args.wait
    attempt = 0
    last = ""
    print(f"Waiting up to {args.wait}s for the database at {args.dsn} ...", flush=True)
    while True:
        attempt += 1
        r = run_duckdb(args.duckdb, sql, 90, env)
        if r.code == 0 and not r.timed_out:
            print(f"Database is ready (attempt {attempt}).", flush=True)
            return True
        lines = [l for l in (r.err + "\n" + r.out).splitlines() if l.strip()]
        last = "the attempt itself timed out" if r.timed_out else (lines[0] if lines else "")
        if time.monotonic() >= deadline:
            break
        print(f"  attempt {attempt}: not ready yet ({hide_secrets(last, env)}); retrying in {args.retry}s", flush=True)
        time.sleep(args.retry)
    print(f"Database did not become ready within {args.wait}s. Last error: {hide_secrets(last, env)}", file=sys.stderr)
    return False


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--duckdb", required=True, help="the DuckDB CLI to run (use the pinned one: tools/fetch-duckdb-cli.sh)")
    ap.add_argument("--extension", required=True, help="the duckdb_oracle.duckdb_extension file, under its shipped name")
    ap.add_argument("--dsn", required=True, help="Oracle connect string, for example localhost:1521/FREEPDB1")
    ap.add_argument("--timeout", type=int, default=180, help="seconds per file unless the file says otherwise")
    ap.add_argument("--wait", type=int, default=0, help="wait up to this many seconds for the database first")
    ap.add_argument("--retry", type=int, default=10, help="seconds between attempts while waiting")
    ap.add_argument("dirs", nargs="+", help="directories of *.sql files, run in this order, each sorted by name")
    args = ap.parse_args(argv)

    env = dict(os.environ)
    for need in ("ORACLE_USER", "ORACLE_PASSWORD"):
        if not env.get(need):
            print(f"{need} is not set in the environment", file=sys.stderr)
            return 2
    if os.path.basename(args.extension) != "duckdb_oracle.duckdb_extension":
        print("the extension must be loaded under its shipped name duckdb_oracle.duckdb_extension", file=sys.stderr)
        return 2
    for p in (args.duckdb, args.extension):
        if not os.path.isfile(p):
            print(f"not found: {p}", file=sys.stderr)
            return 2
    print(f"DSN: {args.dsn}   user: {env['ORACLE_USER']}   password: from $ORACLE_PASSWORD (not shown)")

    report = []
    if args.wait > 0:
        ready = wait_for_database(args, env)
        report.append(("PASS" if ready else "FAIL", "database ready", args.dsn if ready else f"no answer within {args.wait}s"))
        if not ready:
            return summarize(report)
    for d in args.dirs:
        files = sorted(f for f in os.listdir(d) if f.endswith(".sql")) if os.path.isdir(d) else []
        if not files:
            report.append(("FAIL", d, "no .sql files"))
            continue
        group = os.path.basename(os.path.normpath(d))
        for f in files:
            run_file(os.path.join(d, f), group, args, env, report)
    return summarize(report)


def summarize(report):
    print("\n==== summary ====")
    for status, name, detail in report:
        print(f"{status:<5} {name}: {detail}")
    failed = [r for r in report if r[0] == "FAIL"]
    warned = [r for r in report if r[0] == "WARN"]
    print(f"{len(report) - len(failed) - len(warned)} passed, {len(warned)} warnings, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
