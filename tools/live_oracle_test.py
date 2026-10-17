#!/usr/bin/env python3
"""Live Oracle test: exercises the code that no offline test can reach.

Runs the loaded extension against a REAL Oracle server through the DuckDB Python
wheel: the describe -> define -> fetch -> convert path, every row of the README
type table that needs no DDL, NULLs, multi-batch fetches, LIMIT (early close),
LOB values beyond one batch, error mapping, the read-only guards and the call
timeout. Test data comes from SELECTs against DUAL, so the account needs no
privileges beyond CREATE SESSION (and SELECT on V$SESSION for the leak check,
which is skipped if it is not granted).

  ORACLE_DSN                  e.g. localhost:1521/FREEPDB1
  ORACLE_USER, ORACLE_PASSWORD
  DUCKDB_ORACLE_EXTENSION     path to duckdb_oracle.duckdb_extension (as shipped)
  needs: pip install duckdb==<version of the vendored headers>

Written without access to an Oracle server: the expected values are independent
literals (SQL literals and their documented Oracle results), but the FIRST RUN
against a real server is also the first time this script has run. A failure may
be a wrong expectation here as easily as a bug in the extension: read the detail.
Exit code 0 only if every check passed (SKIPs are listed, not hidden).
"""
import datetime
import decimal
import os
import sys
import time

import duckdb

DSN = os.environ.get("ORACLE_DSN", "")
EXT = os.environ.get("DUCKDB_ORACLE_EXTENSION", "")

results = []  # (status, name, detail)


def record(status, name, detail=""):
    results.append((status, name, detail))
    print(f"{status:5} {name}" + (f"\n        {detail}" if detail and status != "PASS" else ""), flush=True)


def lit(s):
    return "'" + s.replace("'", "''") + "'"


def connect():
    con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
    con.execute(f"LOAD {lit(EXT)}")
    return con


def q(con, sql, opts=""):
    """Run an Oracle query through oracle_query and return rows."""
    return con.execute(f"SELECT * FROM oracle_query({lit(DSN)}, {lit(sql)}{opts})").fetchall()


def q_sql(con, sql, wrapper, opts=""):
    """oracle_query result post-processed in DuckDB: wrapper contains {src}."""
    src = f"oracle_query({lit(DSN)}, {lit(sql)}{opts})"
    return con.execute(wrapper.format(src=src)).fetchall()


class Skip(Exception):
    """The check does not apply to this server/client/account."""


def check(name, fn):
    try:
        fn()
        record("PASS", name)
    except Skip as e:
        record("SKIP", name, str(e))
    except AssertionError as e:
        record("FAIL", name, f"assertion: {e}")
    except Exception as e:  # noqa: BLE001 - a crash or DuckDB error is a failed check, not a stop
        record("FAIL", name, f"{type(e).__name__}: {str(e)[:600]}")


def expect_error(con, sql, *needles, opts=""):
    try:
        q(con, sql, opts)
    except duckdb.Error as e:
        text = str(e)
        assert any(n in text for n in needles), f"error did not mention {needles}: {text[:400]}"
        return text
    raise AssertionError("expected an error, the query succeeded")


def main():
    if not (DSN and EXT and os.environ.get("ORACLE_USER") and os.environ.get("ORACLE_PASSWORD")):
        print("FAIL: set ORACLE_DSN, ORACLE_USER, ORACLE_PASSWORD and DUCKDB_ORACLE_EXTENSION")
        return 2
    con = connect()

    # Without a working connection nothing else is meaningful: say so once.
    try:
        q(con, "SELECT 1 AS one FROM dual")
    except duckdb.Error as e:
        print(f"FAIL: cannot run SELECT 1 FROM dual against {DSN}:\n  {str(e)[:700]}")
        return 1
    record("PASS", "connect and SELECT 1 FROM dual")

    info = con.execute("SELECT client_version FROM oracle_client_info()").fetchone()[0]
    client_major = int(info.split(".")[0]) if info else 0
    print(f"      Oracle client {info}")

    # ---- scalar types -------------------------------------------------------
    def scalars():
        r = q(con, """SELECT CAST(42 AS NUMBER(10,0)) a, CAST(123.45 AS NUMBER(10,2)) b, CAST(1.5 AS BINARY_DOUBLE) c,
                             CAST(2.5 AS BINARY_FLOAT) d, 'h\u00e9llo \u20ac' e, CAST('ab' AS CHAR(5)) f,
                             TO_DATE('2024-02-29 13:45:30','YYYY-MM-DD HH24:MI:SS') g,
                             TIMESTAMP '2024-02-29 13:45:30.123456' h FROM dual""")[0]
        want = (42, decimal.Decimal("123.45"), 1.5, 2.5, "h\u00e9llo \u20ac", "ab   ",
                datetime.datetime(2024, 2, 29, 13, 45, 30), datetime.datetime(2024, 2, 29, 13, 45, 30, 123456))
        assert r == want, f"{r!r} != {want!r}"
    check("scalars: NUMBER(p,0), NUMBER(p,s), BINARY_*, VARCHAR2 UTF-8, CHAR padding, DATE, TIMESTAMP", scalars)

    def wide_decimal():
        r = q(con, "SELECT CAST(12345678901234567890123456789012345678 AS NUMBER(38,0)) FROM dual")[0][0]
        assert r == decimal.Decimal("12345678901234567890123456789012345678"), r
    check("NUMBER(38,0) is an exact DECIMAL", wide_decimal)

    def tz():
        r = q_sql(con, "SELECT TIMESTAMP '2024-01-01 10:00:00 +05:30' AS t FROM dual", "SELECT epoch_us(t) FROM {src}")[0][0]
        assert r == 1704083400000000, r  # 2024-01-01 04:30:00 UTC
    check("TIMESTAMP WITH TIME ZONE becomes the right UTC instant", tz)

    def intervals():
        r = q_sql(con, "SELECT INTERVAL '3 04:05:06' DAY TO SECOND AS a, INTERVAL '2-3' YEAR TO MONTH AS b FROM dual",
                  "SELECT a::VARCHAR, b::VARCHAR FROM {src}")[0]
        assert r[0] == "3 days 04:05:06" and r[1] == "2 years 3 months", r
    check("INTERVAL DAY TO SECOND and YEAR TO MONTH", intervals)

    def nulls():
        r = q(con, """SELECT CAST(NULL AS NUMBER(5,0)), CAST(NULL AS NUMBER(10,2)), CAST(NULL AS VARCHAR2(5)),
                             CAST(NULL AS DATE), CAST(NULL AS TIMESTAMP), CAST(NULL AS CLOB), CAST(NULL AS RAW(4)),
                             CAST(NULL AS BINARY_DOUBLE) FROM dual""")[0]
        assert all(v is None for v in r), r
    check("NULL in every type family", nulls)

    # ---- the NUMBER policy (review F1): never silently rounded -------------------
    def never_rounded():
        sql = "SELECT 9007199254740993 AS big FROM dual"  # 2^53 + 1
        try:
            r = q(con, sql)[0][0]
        except duckdb.Error as e:
            assert "cannot be represented exactly" in str(e), str(e)[:400]
            return  # refused loudly: fine
        assert int(r) == 9007199254740993, f"silently rounded to {r!r}"
    check("2^53+1 is an error or exact, never silently rounded (default)", never_rounded)

    def as_varchar():
        r = q(con, "SELECT 9007199254740993 AS big FROM dual", ", unconstrained_number := 'varchar'")[0][0]
        assert r == "9007199254740993", r
    check("unconstrained_number := 'varchar' returns the exact text", as_varchar)

    # ---- LOB / RAW / ROWID -------------------------------------------------------
    def clob():
        pieces = " || ".join(f"TO_CLOB(RPAD('{c}', 4000, '{c}'))" for c in "abcdefghij" * 5)  # 50 x 4000 = 200000 chars
        r = q(con, f"SELECT {pieces} AS c FROM dual")[0][0]
        assert len(r) == 200000 and r[:4000] == "a" * 4000 and r[-4000:] == "j" * 4000, (len(r), r[:10])
    check("CLOB of 200,000 characters", clob)

    def raw_blob():
        r = q(con, "SELECT HEXTORAW('00FF10') r, TO_BLOB(HEXTORAW('DEADBEEF')) b FROM dual")[0]
        assert r == (b"\x00\xff\x10", b"\xde\xad\xbe\xef"), r
    check("RAW and BLOB", raw_blob)

    def rowid():
        r = q(con, "SELECT ROWID FROM dual")[0][0]
        assert isinstance(r, str) and len(r) >= 15, repr(r)
    check("ROWID as text", rowid)

    # ---- batches, LIMIT, handles ---------------------------------------------------
    def multi_batch():
        r = q_sql(con, "SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 5000", "SELECT count(*), sum(n) FROM {src}")[0]
        assert r[0] == 5000 and r[1] == 12502500, r
    check("5000 rows over several fetch batches", multi_batch)

    def limit():
        r = q_sql(con, "SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 100000000", "SELECT n FROM {src} LIMIT 3")
        assert len(r) == 3, r
    check("LIMIT stops a 100M-row query promptly", limit)

    def no_session_leak():
        count = "SELECT COUNT(*) FROM v$session WHERE username = USER"
        try:
            n0 = q(con, count)[0][0]
        except duckdb.Error as e:
            if "ORA-00942" in str(e):
                raise Skip("no SELECT on V$SESSION for this user")
            raise
        for _ in range(60):
            q_sql(con, "SELECT LEVEL FROM dual CONNECT BY LEVEL <= 100000", "SELECT * FROM {src} LIMIT 1")
        time.sleep(1)
        n1 = q(con, count)[0][0]
        assert n1 <= n0 + 3, f"sessions grew from {n0} to {n1} after 60 LIMIT queries"
    check("sessions are released after 60 LIMIT queries (leak check)", no_session_leak)

    # ---- errors and guards -----------------------------------------------------------
    check("an Oracle error is a DuckDB error with the ORA code",
          lambda: expect_error(con, "SELECT * FROM no_such_table_xyz", "ORA-00942"))
    check("DDL is refused", lambda: expect_error(con, "CREATE TABLE duckdb_oracle_ci_x (a NUMBER)", "only runs queries"))
    check("DML is refused", lambda: expect_error(con, "DELETE FROM duckdb_oracle_ci_x", "only runs queries"))
    check("SELECT ... FOR UPDATE is refused", lambda: expect_error(con, "SELECT * FROM dual FOR UPDATE", "FOR UPDATE"))

    def semicolon():
        assert q(con, "SELECT 7 AS n FROM dual;")[0][0] in (7, 7.0)
    check("a trailing semicolon is tolerated", semicolon)

    def wrong_password_does_not_leak():
        os.environ["LIVE_TEST_BAD_PW"] = "wrong-pw-should-not-appear-9f3a"
        try:
            con.execute(f"SELECT * FROM oracle_query({lit(DSN)}, 'SELECT 1 FROM dual', password_env := 'LIVE_TEST_BAD_PW')").fetchall()
        except duckdb.Error as e:
            text = str(e)
            assert "ORA-01017" in text, text[:300]
            assert "wrong-pw-should-not-appear-9f3a" not in text, "the password appeared in the error"
            return
        raise AssertionError("login with a wrong password succeeded")
    check("a wrong password is ORA-01017 and is never echoed", wrong_password_does_not_leak)

    def call_timeout():
        t0 = time.time()
        text = expect_error(con, "SELECT COUNT(*) FROM (SELECT LEVEL FROM dual CONNECT BY LEVEL <= 2000000000)",
                            "DPI-1067", "ORA-03156", "timeout", opts=", timeout := 2")
        assert time.time() - t0 < 60, f"took {time.time() - t0:.0f}s"
    check("timeout := 2 ends a long query with a timeout error", call_timeout)

    # ---- 23ai types (only when the client can carry them) -----------------------------------
    if client_major >= 23:
        def boolean():
            try:
                r = q(con, "SELECT TRUE AS t, FALSE AS f FROM dual")[0]
            except duckdb.Error as e:
                if "ORA-00923" in str(e) or "ORA-00904" in str(e):
                    raise Skip("server older than 23ai")
                raise
            assert r == (True, False), r
        check("23ai BOOLEAN", boolean)

        def vector():
            try:
                r = q(con, "SELECT TO_VECTOR('[1.5, 2.5, 3.5]', 3, FLOAT32) FROM dual")[0][0]
            except duckdb.Error as e:
                if "ORA-00904" in str(e) or "ORA-00923" in str(e):
                    raise Skip("server older than 23ai")
                raise
            assert list(r) == [1.5, 2.5, 3.5], r
        check("23ai VECTOR", vector)
    else:
        record("SKIP", "23ai BOOLEAN / VECTOR", f"Oracle client {info} is older than 23")

    failed = [r for r in results if r[0] == "FAIL"]
    skipped = [r for r in results if r[0] == "SKIP"]
    print(f"\n{len(results) - len(failed) - len(skipped)} passed, {len(failed)} failed, {len(skipped)} skipped")
    for _, name, detail in skipped:
        print(f"  skipped: {name} ({detail})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
