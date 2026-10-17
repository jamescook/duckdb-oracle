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
| `MDSYS.SDO_GEOMETRY` (Oracle Locator / Spatial) | `BLOB` (WKB), or `VARCHAR` (WKT) with `geometry := 'wkt'` | converted inside Oracle, see [Spatial data](#spatial-data-sdo_geometry) |
| any other object type, `BFILE`, `REF CURSOR`, other | bind-time error | `duckdb_oracle: column N ("X") has unsupported Oracle type BFILE; convert it in the query, e.g. TO_CHAR(...) or JSON_SERIALIZE(...)`. For an object type the message names it: `unsupported Oracle object type MDSYS.SDO_POINT_TYPE` |

On a 19c server none of the 23ai rows can occur, so 19c behaviour does not depend on them.

## Spatial data (SDO_GEOMETRY)

A column of the Oracle object type `MDSYS.SDO_GEOMETRY` is found when the query is described, and Oracle itself converts it: no
object type ever reaches the client library. duckdb-oracle runs the query wrapped as

```sql
SELECT q."ID", MDSYS.SDO_UTIL.TO_WKBGEOMETRY(q."SHAPE") FROM (
<your query>
) q
```

(one conversion per geometry column; each column is referenced by its quoted name, so case-sensitive and spaced names work). If two
columns share a name, or a name cannot be written as a quoted identifier, the columns are renamed by position with a `WITH` column
list instead. Queries without a geometry column are never rewritten. Notes: an `ORDER BY` inside your query is kept in practice, but
SQL does not promise that an outer `SELECT` preserves it; and a query that itself starts with `WITH` *and* has duplicate column names
needs Oracle to accept a `WITH` inside the generated one.

| `geometry :=` | DuckDB type | Oracle function |
|---|---|---|
| `'wkb'` (default) | `BLOB` | `SDO_UTIL.TO_WKBGEOMETRY` |
| `'wkt'` | `VARCHAR` | `SDO_UTIL.TO_WKTGEOMETRY` |

`geometry_srid := true` adds an extra column `<name>_srid` (`BIGINT`) right after every geometry column, taken from the geometry's
`SDO_SRID` attribute.

```sql
-- DuckDB 1.5 and later have these in core; older DuckDB needs INSTALL spatial; LOAD spatial;
SELECT id, ST_AsText(ST_GeomFromWKB(shape)) AS wkt, shape_srid
FROM oracle_query('localhost:1521/ORCLPDB1', 'SELECT id, shape FROM parcels', geometry_srid := true);
```

**Why `BLOB` and not DuckDB's `GEOMETRY` type?** The extension is built against the stable C API of DuckDB **1.2.0** so that it
loads on every release from 1.2 on. `GEOMETRY` (`DUCKDB_TYPE_GEOMETRY`) appears in the 1.5.x headers only, and the sole stable
function that mentions it, `duckdb_geometry_type_get_crs`, *reads* the CRS of an existing type and only since 1.5.6: there is no
stable way to create the type, let alone with a CRS, and an extension that used it could not load on older DuckDB. WKB in a `BLOB`
loads everywhere, and `ST_GeomFromWKB` (spatial extension, or core from 1.5) turns it into a `GEOMETRY`. DuckDB 1.5.6 does not cast
a `BLOB` to `GEOMETRY` directly; use `ST_GeomFromWKB`.

What survives the conversion, and what does not:

* **Coordinates and the geometry kind** (point, line, polygon with holes, multi-point/line/polygon, collection) are what Oracle's
  converter writes; **NULL geometries stay NULL**.
* **The SRID is not in WKB**, so it is dropped unless you ask for `geometry_srid := true`. A geometry with no SRID has a NULL SRID.
* **3D and measured geometries, circular arcs and other shapes** are whatever `TO_WKBGEOMETRY` / `TO_WKTGEOMETRY` do with them. If
  Oracle refuses a geometry, its `ORA-` error is raised while fetching. The e2e test `test/e2e/spatial/04_3d_geometries.sql`
  records what a 3D point becomes.
* The conversion functions belong to **Oracle Locator**, which Oracle documents as included with Oracle XE and with every Database
  edition; Oracle Database Free is documented to include spatial features as well. If a database lacks it, the error says so and
  names the function. `test/e2e/spatial/00_probe_locator.sql` checks it against a real database (the hosted CI runs it on Free 23ai
  and XE 21c).

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
