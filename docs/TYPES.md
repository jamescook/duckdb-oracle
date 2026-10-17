# Oracle to DuckDB type mapping

How each Oracle column type arrives in DuckDB. NULLs map to DuckDB NULLs for every type. For the arguments that change some of
these mappings, see [REFERENCE.md](REFERENCE.md#oracle_query).

| Oracle | DuckDB | Notes |
|---|---|---|
| `NUMBER(p,0)`, p ≤ 18 (also `NUMBER(p,-s)` with p+s ≤ 18) | `BIGINT` | fetched as int64 |
| `NUMBER(p,s)`, s > 0, max(p,s) ≤ 38; `NUMBER(19..38,0)` | `DECIMAL(max(p,s), s)` | exact: fetched as text, parsed to the scaled integer, stored as int16/32/64/128 |
| `NUMBER` (no precision), `FLOAT(b)`, `NUMBER(p,-s)` with p+s > 38, `NUMBER(p,s)` wider than 38 | `DOUBLE` (checked) | see [Unconstrained NUMBER](#unconstrained-number) |
| `BINARY_DOUBLE` | `DOUBLE` | |
| `BINARY_FLOAT` | `FLOAT` | |
| `VARCHAR2`, `NVARCHAR2`, `CHAR`, `NCHAR` | `VARCHAR` | UTF-8 (the connection uses UTF-8 for both character sets). `CHAR` keeps Oracle's blank padding |
| `CLOB`, `NCLOB`, `LONG` | `VARCHAR` | fetched inline as LONG, so values are held in memory; see [LOBs](#lobs) |
| `XMLTYPE` | `VARCHAR` | |
| `ROWID`, `UROWID` | `VARCHAR` | the textual ROWID |
| `DATE`, `TIMESTAMP(n)` | `TIMESTAMP` | microsecond precision (fractional nanoseconds are truncated) |
| `TIMESTAMP WITH TIME ZONE`, `TIMESTAMP WITH LOCAL TIME ZONE` | `TIMESTAMPTZ` | converted to UTC with the offset the Oracle client returns. Region names are not preserved |
| `RAW`, `LONG RAW`, `BLOB` | `BLOB` | |
| `INTERVAL DAY TO SECOND` / `YEAR TO MONTH` | `INTERVAL` | a `YEAR TO MONTH` value whose months do not fit in 32 bits (more than about 178 million years) is an error |
| `BOOLEAN` (23ai+ server, 23ai+ client) | `BOOLEAN` | |
| `JSON` (21c+ native type; 21c+ client) and `BLOB ... IS JSON (FORMAT OSON)` | `VARCHAR` (JSON text) | serialised to compact JSON text. Non-JSON scalars follow `JSON_SERIALIZE` conventions: RAW → uppercase hex string, DATE/TIMESTAMP → ISO 8601 string, INTERVAL → ISO 8601 duration, NaN/±Inf → strings. Numbers keep their exact decimal text. Key order is whatever OSON returns. Use DuckDB's `json_*` functions on the result |
| `VECTOR(n, FLOAT32)` (23ai+ server and client) | `FLOAT[]` | |
| `VECTOR(n, FLOAT64)` | `DOUBLE[]` | |
| `VECTOR(n, INT8)` | `FLOAT[]` | int8 → float is exact |
| `VECTOR(*, *)` (flexible format) | `DOUBLE[]` | each value converted from its own storage format |
| `VECTOR(n, BINARY)` | `UTINYINT[]` | the packed bytes, n/8 elements (a float list of bits would be misleading) |
| sparse `VECTOR` (23.7+) | same as dense | densified (zeros for absent dimensions); rejected above 16M elements |
| `OBJECT`, `BFILE`, `REF CURSOR`, other | bind-time error | `duckdb_oracle: column N ("X") has unsupported Oracle type OBJECT; convert it in the query, e.g. TO_CHAR(...) or JSON_SERIALIZE(...)` |

On a 19c server none of the 23ai rows can occur, so 19c behaviour does not depend on them.

## Unconstrained NUMBER

Oracle reports a `NUMBER` with no precision, `FLOAT(b)`, and expressions such as `COUNT(*)`, `SUM(...)` or `1/3` as an
"unconstrained" number, so these arrive as `DOUBLE`. They are fetched as text and an **integral value that a double cannot hold
exactly (for example `9007199254740993`) is an error**, not a silently rounded number. Fractions are approximate, as in any
`DOUBLE`. Ways to get exact values:

* Cast in the Oracle SQL: `CAST(x AS NUMBER(p,s))`, for example `CAST(COUNT(*) AS NUMBER(18,0))` arrives as `BIGINT`.
* `unconstrained_number := 'varchar'` returns the exact text.
* `unconstrained_number := 'lossy_double'` is the previous behaviour: silent rounding.

## LOBs

`CLOB`, `NCLOB` and `BLOB` values are fetched inline (as `LONG` / `LONG RAW`), so no LOB locators are ever handed out and nothing can
leak when a scan stops early. The price is that each value is held in memory while it is fetched. Because those buffers grow to the
value's real size, queries with LOB columns fetch fewer rows per batch (at most 64 rows for a single LOB column) than queries
without. Very large LOBs (hundreds of megabytes each) can still use a lot of memory.

## Client requirements for 23ai/26ai types

The server types only reach duckdb-oracle if the Oracle client understands them: `BOOLEAN` and `VECTOR` need Instant Client **23ai or
newer**, native `JSON` needs **21c or newer**. With the 19.26 client against a 23ai server, plain 19c-style queries work, but a column
of those types is expected to fail at bind time with an Oracle error or the "unsupported Oracle type" message (expected behaviour, not
verified against a server). Workarounds with an old client: `JSON_SERIALIZE(col)`, `FROM_VECTOR(col)`,
`CASE WHEN b THEN 1 ELSE 0 END`.
