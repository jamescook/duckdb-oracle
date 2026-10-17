//! Column module: what an Oracle column becomes in DuckDB, end to end.
//!
//! For one result column this module decides the DuckDB type (`plan`), the
//! ODPI-C define parameters (`oracle_type`/`native_type`/`size`), the fetch buffer
//! cost (`bufferBytes`) and how one fetched value is written into a DuckDB vector
//! (`write`). Every switch on the column kind lives here, so supporting a new type
//! or changing a mapping policy is an edit to this file.
//!
//! Two seams keep it testable without DuckDB or Oracle:
//!   * the vector sink  - where values go. Production: DuckDB vectors
//!     (duckdb_oracle.zig `DuckSink`); tests: an in-memory sink.
//!       data() [*]u8                 raw fixed-width buffer; list entries are written into it
//!       setNull(row)                 string(row, bytes)
//!       listSize() u64               listReserve(total) bool      listChildData() ?[*]u8  listSetSize(n)
//!   * the handle reader - ODPI-C values that are opaque handles (VECTOR, JSON, ROWID).
//!     Production: odpi_backend.zig `OdpiReader`; tests: canned values.
//!       readVector(handle, *dpiVectorInfo) !void
//!       readJson(handle) !*const dpiJsonNode        readRowid(handle) ![]const u8
//!
//! Pure value primitives (timestamps, decimals, JSON text, vector copies) are in
//! convert.zig.
const std = @import("std");
const c = @import("c.zig").c;
const convert = @import("convert.zig");

/// The DuckDB type a column is materialised as.
pub const Kind = enum {
    bigint,
    decimal,
    double,
    /// DOUBLE fetched as NUMBER text and checked for silent integer rounding
    number_double,
    float,
    boolean,
    varchar,
    /// ROWID / UROWID: a dpiRowid handle turned into text; VARCHAR in DuckDB
    rowid,
    /// Oracle 23ai+ JSON / OSON BLOB: a dpiJson tree serialised to text; VARCHAR in DuckDB
    json,
    blob,
    timestamp,
    timestamptz,
    interval,
    /// LIST of `Column.list_elem` (Oracle 23ai+ VECTOR)
    list,

    pub fn duckdbType(self: Kind) c.duckdb_type {
        return switch (self) {
            .bigint => c.DUCKDB_TYPE_BIGINT,
            .decimal => c.DUCKDB_TYPE_DECIMAL,
            .double, .number_double => c.DUCKDB_TYPE_DOUBLE,
            .float => c.DUCKDB_TYPE_FLOAT,
            .boolean => c.DUCKDB_TYPE_BOOLEAN,
            .varchar, .rowid, .json => c.DUCKDB_TYPE_VARCHAR,
            .blob => c.DUCKDB_TYPE_BLOB,
            .timestamp => c.DUCKDB_TYPE_TIMESTAMP,
            .timestamptz => c.DUCKDB_TYPE_TIMESTAMP_TZ,
            .interval => c.DUCKDB_TYPE_INTERVAL,
            .list => c.DUCKDB_TYPE_LIST,
        };
    }
};

pub const ListElem = convert.ListElem;

/// How to define (fetch) one Oracle column and what to turn it into.
pub const Column = struct {
    kind: Kind,
    /// DECIMAL width/scale (only for .decimal)
    width: u8 = 0,
    scale: u8 = 0,
    /// arguments for dpiConn_newVar()
    oracle_type: c.dpiOracleTypeNum,
    native_type: c.dpiNativeTypeNum,
    size: u32 = 0,
    size_is_bytes: bool = true,
    /// element type of a .list column (VECTOR)
    list_elem: ListElem = .double,

    /// What DuckDB needs to build this column's logical type (no DuckDB calls here).
    pub const LogicalSpec = struct {
        id: c.duckdb_type,
        width: u8 = 0,
        scale: u8 = 0,
        /// element type when `id` is LIST
        child: ?c.duckdb_type = null,
    };

    pub fn logicalSpec(self: *const Column) LogicalSpec {
        return switch (self.kind) {
            .decimal => .{ .id = c.DUCKDB_TYPE_DECIMAL, .width = self.width, .scale = self.scale },
            .list => .{ .id = c.DUCKDB_TYPE_LIST, .child = self.list_elem.duckdbType() },
            else => .{ .id = self.kind.duckdbType() },
        };
    }

    /// Fetch buffer ODPI-C is assumed to allocate per row (see `fetchRows`).
    pub const lob_assumed_bytes: u64 = 1 << 20;

    /// Approximate per-row fetch buffer bytes ODPI-C allocates for this column.
    /// LONG / LOB-as-LONG / XMLTYPE buffers grow to the real value size (up to
    /// 1 GB), so they are budgeted at `lob_assumed_bytes` per row, not a small
    /// nominal chunk: a batch of 2048 multi-megabyte CLOBs would not fit in memory.
    pub fn bufferBytes(self: *const Column) u64 {
        const overhead: u64 = 24; // dpiData + indicator/length/return code
        switch (self.kind) {
            .decimal, .number_double => return overhead + 172, // DPI_NUMBER_AS_TEXT_CHARS
            .json, .list => return overhead + 256, // descriptor; value materialised per row
            else => {},
        }
        // NUMBER fetched as text (varchar mode)
        if (self.oracle_type == c.DPI_ORACLE_TYPE_NUMBER and self.native_type == c.DPI_NATIVE_TYPE_BYTES) return overhead + 172;
        if (self.oracle_type == c.DPI_ORACLE_TYPE_LONG_VARCHAR or self.oracle_type == c.DPI_ORACLE_TYPE_LONG_NVARCHAR or
            self.oracle_type == c.DPI_ORACLE_TYPE_LONG_RAW or self.oracle_type == c.DPI_ORACLE_TYPE_XMLTYPE) return overhead + lob_assumed_bytes;
        return overhead + @max(self.size, 16);
    }

    pub const WriteCtx = struct {
        gpa: std.mem.Allocator,
        /// scratch buffer for JSON text, reused across rows
        json_buf: *std.ArrayList(u8),
    };

    pub const WriteError = convert.FixedError || convert.JsonError || convert.VectorError ||
        error{ ReadVector, ReadJson, ReadRowid, ListReserve };

    /// Write one fetched value into `sink` at `row` (NULL included).
    pub fn write(self: *const Column, sink: anytype, reader: anytype, ctx: WriteCtx, row: u32, d: *const c.dpiData) WriteError!void {
        if (d.isNull != 0) {
            if (self.kind == .list) setListEntry(sink, row, sink.listSize(), 0);
            sink.setNull(row);
            return;
        }
        switch (self.kind) {
            .list => {
                var vi = std.mem.zeroes(c.dpiVectorInfo);
                reader.readVector(d.value.asVector, &vi) catch return error.ReadVector;
                const n = try convert.vectorLen(&vi, self.list_elem);
                const list_size = sink.listSize();
                if (!sink.listReserve(list_size + n)) return error.ListReserve;
                // fetched after the reserve: it may have reallocated the child buffer
                const child = sink.listChildData() orelse return error.ListReserve;
                try convert.convertVector(&vi, self.list_elem, child + list_size * self.list_elem.size());
                setListEntry(sink, row, list_size, n);
                sink.listSetSize(list_size + n);
            },
            .json => {
                const top = reader.readJson(d.value.asJson) catch return error.ReadJson;
                ctx.json_buf.clearRetainingCapacity();
                try convert.serializeJson(ctx.gpa, ctx.json_buf, top);
                sink.string(row, ctx.json_buf.items);
            },
            .rowid => sink.string(row, reader.readRowid(d.value.asRowid) catch return error.ReadRowid),
            .varchar, .blob => {
                const b = d.value.asBytes;
                sink.string(row, if (b.ptr == null) "" else b.ptr[0..b.length]);
            },
            else => try self.writeFixed(&d.value, sink.data(), row),
        }
    }

    fn setListEntry(sink: anytype, row: u32, offset: u64, length: u64) void {
        const entries: [*]c.duckdb_list_entry = @ptrCast(@alignCast(sink.data()));
        entries[row] = .{ .offset = offset, .length = length };
    }

    /// Convert one non-NULL value of a fixed-width kind and store it at `row`.
    pub fn writeFixed(self: *const Column, value: *const c.dpiDataBuffer, data: [*]u8, row: usize) convert.FixedError!void {
        switch (self.kind) {
            .bigint => @as([*]i64, @ptrCast(@alignCast(data)))[row] = value.asInt64,
            .double => @as([*]f64, @ptrCast(@alignCast(data)))[row] = value.asDouble,
            .float => @as([*]f32, @ptrCast(@alignCast(data)))[row] = value.asFloat,
            .boolean => @as([*]bool, @ptrCast(@alignCast(data)))[row] = value.asBoolean != 0,
            .number_double => {
                const b = value.asBytes;
                const text: []const u8 = if (b.length == 0) "" else b.ptr[0..b.length];
                @as([*]f64, @ptrCast(@alignCast(data)))[row] = try convert.parseNumberAsDouble(text);
            },
            .timestamp => @as([*]i64, @ptrCast(@alignCast(data)))[row] = convert.timestampMicros(&value.asTimestamp),
            .timestamptz => @as([*]i64, @ptrCast(@alignCast(data)))[row] = convert.timestampTzMicros(&value.asTimestamp),
            .interval => @as([*]c.duckdb_interval, @ptrCast(@alignCast(data)))[row] = if (self.native_type == c.DPI_NATIVE_TYPE_INTERVAL_YM)
                try convert.intervalYM(&value.asIntervalYM)
            else
                convert.intervalDS(&value.asIntervalDS),
            .decimal => {
                const b = value.asBytes;
                const text: []const u8 = if (b.length == 0) "" else b.ptr[0..b.length];
                convert.storeDecimal(data, row, self.width, try convert.parseDecimal(text, self.width, self.scale));
            },
            .varchar, .rowid, .json, .blob, .list => return error.NotFixed,
        }
    }
};

pub const PlanError = error{UnsupportedType};

/// Largest precision for which NUMBER(p,0) becomes BIGINT.
pub const max_bigint_precision = 18;

/// How NUMBER columns that have no exact DECIMAL form are materialised: a bare
/// NUMBER, FLOAT(b), COUNT(*)/SUM() expressions, NUMBER(p,s) wider than 38 digits.
pub const NumberMode = enum {
    /// DOUBLE; an integral value that a double cannot hold exactly is an error
    /// instead of being silently rounded (the default).
    double,
    /// DOUBLE with silent rounding (fast path: OCI converts to double itself).
    lossy_double,
    /// Exact NUMBER text as VARCHAR.
    varchar,

    pub fn parse(text: []const u8) ?NumberMode {
        // an explicit table: @typeInfo's enum layout differs between Zig 0.15 and 0.17
        const names = [_]struct { []const u8, NumberMode }{ .{ "double", .double }, .{ "lossy_double", .lossy_double }, .{ "varchar", .varchar } };
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(text, n[0])) return n[1];
        }
        return null;
    }
};

pub const PlanOptions = struct { number: NumberMode = .double };

/// Decide the DuckDB type and the ODPI-C define parameters for a column.
pub fn fromTypeInfo(ti: *const c.dpiDataTypeInfo, opts: PlanOptions) PlanError!Column {
    const ot = ti.oracleTypeNum;
    switch (ot) {
        c.DPI_ORACLE_TYPE_NUMBER => return planNumber(ti.precision, ti.scale, opts.number),
        c.DPI_ORACLE_TYPE_NATIVE_DOUBLE => return .{ .kind = .double, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_DOUBLE },
        c.DPI_ORACLE_TYPE_NATIVE_FLOAT => return .{ .kind = .float, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_FLOAT },
        c.DPI_ORACLE_TYPE_NATIVE_INT, c.DPI_ORACLE_TYPE_NATIVE_UINT => return .{ .kind = .bigint, .oracle_type = c.DPI_ORACLE_TYPE_NUMBER, .native_type = c.DPI_NATIVE_TYPE_INT64 },
        c.DPI_ORACLE_TYPE_BOOLEAN => return .{ .kind = .boolean, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BOOLEAN },

        c.DPI_ORACLE_TYPE_VARCHAR, c.DPI_ORACLE_TYPE_NVARCHAR, c.DPI_ORACLE_TYPE_CHAR, c.DPI_ORACLE_TYPE_NCHAR => return .{
            .kind = .varchar,
            .oracle_type = ot,
            .native_type = c.DPI_NATIVE_TYPE_BYTES,
            // client size already accounts for the UTF-8 expansion ratio
            .size = @max(ti.clientSizeInBytes, 1),
        },
        // LOBs and LONGs are fetched inline as (dynamically sized) strings /
        // bytes by defining them as LONG_VARCHAR / LONG_RAW. No LOB locators
        // are ever handed out, so nothing can leak if a scan stops early.
        // (same approach as python-oracledb thick mode with fetch_lobs=False)
        c.DPI_ORACLE_TYPE_CLOB, c.DPI_ORACLE_TYPE_LONG_VARCHAR => return .{
            .kind = .varchar,
            .oracle_type = c.DPI_ORACLE_TYPE_LONG_VARCHAR,
            .native_type = c.DPI_NATIVE_TYPE_BYTES,
        },
        c.DPI_ORACLE_TYPE_NCLOB, c.DPI_ORACLE_TYPE_LONG_NVARCHAR => return .{
            .kind = .varchar,
            .oracle_type = c.DPI_ORACLE_TYPE_LONG_NVARCHAR,
            .native_type = c.DPI_NATIVE_TYPE_BYTES,
        },
        c.DPI_ORACLE_TYPE_XMLTYPE => return .{ .kind = .varchar, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES },
        c.DPI_ORACLE_TYPE_ROWID, c.DPI_ORACLE_TYPE_UROWID => return .{ .kind = .rowid, .oracle_type = c.DPI_ORACLE_TYPE_ROWID, .native_type = c.DPI_NATIVE_TYPE_ROWID },

        // Oracle 23ai+ native JSON: fetched as a dpiJson tree and serialised to text.
        c.DPI_ORACLE_TYPE_JSON => return jsonPlan(),
        // Oracle 23ai+ VECTOR: LIST by element format.
        c.DPI_ORACLE_TYPE_VECTOR => return .{
            .kind = .list,
            .oracle_type = ot,
            .native_type = c.DPI_NATIVE_TYPE_VECTOR,
            .list_elem = vectorElem(ti.vectorFormat),
        },

        c.DPI_ORACLE_TYPE_RAW => return .{ .kind = .blob, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES, .size = @max(ti.dbSizeInBytes, 1) },
        // BLOB ... IS JSON (FORMAT OSON): binary JSON, fetch as JSON text
        c.DPI_ORACLE_TYPE_BLOB => if (ti.isOson != 0) return jsonPlan() else return .{ .kind = .blob, .oracle_type = c.DPI_ORACLE_TYPE_LONG_RAW, .native_type = c.DPI_NATIVE_TYPE_BYTES },
        c.DPI_ORACLE_TYPE_LONG_RAW => return .{ .kind = .blob, .oracle_type = c.DPI_ORACLE_TYPE_LONG_RAW, .native_type = c.DPI_NATIVE_TYPE_BYTES },

        c.DPI_ORACLE_TYPE_DATE, c.DPI_ORACLE_TYPE_TIMESTAMP => return .{ .kind = .timestamp, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_TIMESTAMP },
        c.DPI_ORACLE_TYPE_TIMESTAMP_TZ, c.DPI_ORACLE_TYPE_TIMESTAMP_LTZ => return .{ .kind = .timestamptz, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_TIMESTAMP },
        c.DPI_ORACLE_TYPE_INTERVAL_DS => return .{ .kind = .interval, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_INTERVAL_DS },
        c.DPI_ORACLE_TYPE_INTERVAL_YM => return .{ .kind = .interval, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_INTERVAL_YM },

        // OBJECT, JSON, VECTOR, BFILE, REF CURSOR, ...
        else => return error.UnsupportedType,
    }
}

fn jsonPlan() Column {
    return .{ .kind = .json, .oracle_type = c.DPI_ORACLE_TYPE_JSON, .native_type = c.DPI_NATIVE_TYPE_JSON };
}

/// VECTOR(n, FLOAT32) -> FLOAT[], FLOAT64 -> DOUBLE[], INT8 -> FLOAT[] (exact),
/// BINARY -> UTINYINT[] (the packed bytes, n/8 elements), flexible (*) -> DOUBLE[].
pub fn vectorElem(format: u8) convert.ListElem {
    return switch (format) {
        c.DPI_VECTOR_FORMAT_FLOAT32, c.DPI_VECTOR_FORMAT_INT8 => .float,
        c.DPI_VECTOR_FORMAT_BINARY => .utinyint,
        else => .double,
    };
}

fn planNumber(precision: i16, scale: i8, mode: NumberMode) Column {
    const ot = c.DPI_ORACLE_TYPE_NUMBER;
    // Fallback for NUMBERs with no exact DECIMAL form (see NumberMode).
    const dbl: Column = switch (mode) {
        .double => .{ .kind = .number_double, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES },
        .lossy_double => .{ .kind = .double, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_DOUBLE },
        .varchar => .{ .kind = .varchar, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES },
    };
    // NUMBER without precision (p=0, s=-127) and FLOAT(b) (p>0, s=-127)
    if (precision <= 0 or scale == -127) return dbl;
    const p: i32 = precision;
    const s: i32 = scale;
    if (s <= 0) {
        // NUMBER(p,0) or NUMBER(p,-n): integers with up to p-s digits
        const digits = p - s;
        if (digits <= max_bigint_precision)
            return .{ .kind = .bigint, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_INT64 };
        if (digits <= convert.max_decimal_width)
            return .{ .kind = .decimal, .width = @intCast(digits), .scale = 0, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES };
        return dbl;
    }
    // NUMBER(p,s), s>0. Oracle allows s > p (e.g. NUMBER(2,5) = 0.000dd).
    const width = @max(p, s);
    if (width <= convert.max_decimal_width)
        return .{ .kind = .decimal, .width = @intCast(width), .scale = @intCast(s), .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES };
    return dbl;
}

/// Rows per fetch: a full DuckDB vector unless the fetch buffers for one batch
/// would exceed `budget` bytes (very wide rows, e.g. many VARCHAR2(4000 CHAR)
/// columns in an AL32UTF8 database), in which case fewer rows are fetched per
/// DuckDB chunk. Always at least 1.
pub fn fetchRows(plans: []const Column, vector_size: u32, budget: u64) u32 {
    var row: u64 = 0;
    for (plans) |*p| row += p.bufferBytes();
    if (row == 0) return vector_size;
    const n = budget / row;
    return @intCast(@max(1, @min(n, vector_size)));
}

/// Human readable Oracle type name for error messages.
pub fn oracleTypeName(ot: c.dpiOracleTypeNum) []const u8 {
    return switch (ot) {
        c.DPI_ORACLE_TYPE_VARCHAR => "VARCHAR2",
        c.DPI_ORACLE_TYPE_NVARCHAR => "NVARCHAR2",
        c.DPI_ORACLE_TYPE_CHAR => "CHAR",
        c.DPI_ORACLE_TYPE_NCHAR => "NCHAR",
        c.DPI_ORACLE_TYPE_ROWID => "ROWID",
        c.DPI_ORACLE_TYPE_RAW => "RAW",
        c.DPI_ORACLE_TYPE_NATIVE_FLOAT => "BINARY_FLOAT",
        c.DPI_ORACLE_TYPE_NATIVE_DOUBLE => "BINARY_DOUBLE",
        c.DPI_ORACLE_TYPE_NATIVE_INT => "BINARY_INTEGER",
        c.DPI_ORACLE_TYPE_NUMBER => "NUMBER",
        c.DPI_ORACLE_TYPE_DATE => "DATE",
        c.DPI_ORACLE_TYPE_TIMESTAMP => "TIMESTAMP",
        c.DPI_ORACLE_TYPE_TIMESTAMP_TZ => "TIMESTAMP WITH TIME ZONE",
        c.DPI_ORACLE_TYPE_TIMESTAMP_LTZ => "TIMESTAMP WITH LOCAL TIME ZONE",
        c.DPI_ORACLE_TYPE_INTERVAL_DS => "INTERVAL DAY TO SECOND",
        c.DPI_ORACLE_TYPE_INTERVAL_YM => "INTERVAL YEAR TO MONTH",
        c.DPI_ORACLE_TYPE_CLOB => "CLOB",
        c.DPI_ORACLE_TYPE_NCLOB => "NCLOB",
        c.DPI_ORACLE_TYPE_BLOB => "BLOB",
        c.DPI_ORACLE_TYPE_BFILE => "BFILE",
        c.DPI_ORACLE_TYPE_STMT => "REF CURSOR",
        c.DPI_ORACLE_TYPE_BOOLEAN => "BOOLEAN",
        c.DPI_ORACLE_TYPE_OBJECT => "OBJECT",
        c.DPI_ORACLE_TYPE_LONG_VARCHAR => "LONG",
        c.DPI_ORACLE_TYPE_LONG_RAW => "LONG RAW",
        c.DPI_ORACLE_TYPE_NATIVE_UINT => "NATIVE_UINT",
        c.DPI_ORACLE_TYPE_JSON => "JSON",
        c.DPI_ORACLE_TYPE_JSON_OBJECT => "JSON OBJECT",
        c.DPI_ORACLE_TYPE_JSON_ARRAY => "JSON ARRAY",
        c.DPI_ORACLE_TYPE_UROWID => "UROWID",
        c.DPI_ORACLE_TYPE_LONG_NVARCHAR => "LONG NVARCHAR",
        c.DPI_ORACLE_TYPE_XMLTYPE => "XMLTYPE",
        c.DPI_ORACLE_TYPE_VECTOR => "VECTOR",
        else => "UNKNOWN",
    };
}

// ---------------------------------------------------------------------------
// Tests (hand-built dpiDataTypeInfo / dpiData values; no DuckDB or OCI needed)
// ---------------------------------------------------------------------------
const testing = std.testing;

fn typeInfo(ot: c.dpiOracleTypeNum, precision: i16, scale: i8) c.dpiDataTypeInfo {
    var ti = std.mem.zeroes(c.dpiDataTypeInfo);
    ti.oracleTypeNum = ot;
    ti.precision = precision;
    ti.scale = scale;
    ti.clientSizeInBytes = 40;
    ti.dbSizeInBytes = 16;
    return ti;
}

fn planOf(ot: c.dpiOracleTypeNum, p: i16, s: i8) !Column {
    const ti = typeInfo(ot, p, s);
    return fromTypeInfo(&ti, .{});
}

fn planWith(ot: c.dpiOracleTypeNum, p: i16, s: i8, mode: NumberMode) !Column {
    const ti = typeInfo(ot, p, s);
    return fromTypeInfo(&ti, .{ .number = mode });
}

fn mkTs(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8, ns: u32, tzh: i8, tzm: i8) c.dpiTimestamp {
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi, .second = s, .fsecond = ns, .tzHourOffset = tzh, .tzMinuteOffset = tzm };
}

fn store(col: Column, value: *const c.dpiDataBuffer, data: [*]u8, row: usize) convert.FixedError!void {
    return col.writeFixed(value, data, row);
}

test "NUMBER mapping" {
    const N = c.DPI_ORACLE_TYPE_NUMBER;
    // NUMBER(p,0), p <= 18 -> BIGINT
    try testing.expectEqual(Kind.bigint, (try planOf(N, 10, 0)).kind);
    try testing.expectEqual(Kind.bigint, (try planOf(N, 18, 0)).kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_INT64), (try planOf(N, 1, 0)).native_type);
    // NUMBER(19..38,0) -> DECIMAL(p,0)
    const p19 = try planOf(N, 19, 0);
    try testing.expectEqual(Kind.decimal, p19.kind);
    try testing.expectEqual(@as(u8, 19), p19.width);
    // NUMBER(p,s) -> DECIMAL(p,s)
    const p102 = try planOf(N, 10, 2);
    try testing.expectEqual(Kind.decimal, p102.kind);
    try testing.expectEqual(@as(u8, 10), p102.width);
    try testing.expectEqual(@as(u8, 2), p102.scale);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_BYTES), p102.native_type);
    const p38 = try planOf(N, 38, 10);
    try testing.expectEqual(@as(u8, 38), p38.width);
    // s > p
    const p25 = try planOf(N, 2, 5);
    try testing.expectEqual(@as(u8, 5), p25.width);
    try testing.expectEqual(@as(u8, 5), p25.scale);
    // negative scale -> integer with p-s digits
    try testing.expectEqual(Kind.bigint, (try planOf(N, 5, -2)).kind);
    try testing.expectEqual(Kind.decimal, (try planOf(N, 30, -5)).kind);
    try testing.expectEqual(Kind.number_double, (try planOf(N, 38, -5)).kind);
    // unconstrained NUMBER and FLOAT(b) -> DOUBLE (checked: see "unconstrained NUMBER follows the number mode")
    try testing.expectEqual(Kind.number_double, (try planOf(N, 0, -127)).kind);
    try testing.expectEqual(Kind.number_double, (try planOf(N, 126, -127)).kind);
}

test "other type mappings" {
    try testing.expectEqual(Kind.double, (try planOf(c.DPI_ORACLE_TYPE_NATIVE_DOUBLE, 0, 0)).kind);
    try testing.expectEqual(Kind.float, (try planOf(c.DPI_ORACLE_TYPE_NATIVE_FLOAT, 0, 0)).kind);
    for ([_]c.dpiOracleTypeNum{ c.DPI_ORACLE_TYPE_VARCHAR, c.DPI_ORACLE_TYPE_NVARCHAR, c.DPI_ORACLE_TYPE_CHAR, c.DPI_ORACLE_TYPE_NCHAR }) |ot| {
        const p = try planOf(ot, 0, 0);
        try testing.expectEqual(Kind.varchar, p.kind);
        try testing.expectEqual(@as(u32, 40), p.size);
    }
    const clob = try planOf(c.DPI_ORACLE_TYPE_CLOB, 0, 0);
    try testing.expectEqual(Kind.varchar, clob.kind);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, c.DPI_ORACLE_TYPE_LONG_VARCHAR), clob.oracle_type);
    const nclob = try planOf(c.DPI_ORACLE_TYPE_NCLOB, 0, 0);
    try testing.expectEqual(Kind.varchar, nclob.kind);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, c.DPI_ORACLE_TYPE_LONG_NVARCHAR), nclob.oracle_type);
    try testing.expectEqual(Kind.blob, (try planOf(c.DPI_ORACLE_TYPE_RAW, 0, 0)).kind);
    const blob = try planOf(c.DPI_ORACLE_TYPE_BLOB, 0, 0);
    try testing.expectEqual(Kind.blob, blob.kind);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, c.DPI_ORACLE_TYPE_LONG_RAW), blob.oracle_type);
    try testing.expectEqual(Kind.timestamp, (try planOf(c.DPI_ORACLE_TYPE_DATE, 0, 0)).kind);
    try testing.expectEqual(Kind.timestamp, (try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP, 0, 0)).kind);
    try testing.expectEqual(Kind.timestamptz, (try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP_TZ, 0, 0)).kind);
    try testing.expectEqual(Kind.timestamptz, (try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP_LTZ, 0, 0)).kind);
    try testing.expectEqual(Kind.interval, (try planOf(c.DPI_ORACLE_TYPE_INTERVAL_DS, 0, 0)).kind);
    try testing.expect((try planOf(c.DPI_ORACLE_TYPE_ROWID, 0, 0)).kind == .rowid);
    try testing.expectError(error.UnsupportedType, planOf(c.DPI_ORACLE_TYPE_OBJECT, 0, 0));
    try testing.expectError(error.UnsupportedType, planOf(c.DPI_ORACLE_TYPE_BFILE, 0, 0));
}

test "fetch batch sizing" {
    const narrow = [_]Column{ try planOf(c.DPI_ORACLE_TYPE_NUMBER, 10, 0), try planOf(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0) };
    try testing.expectEqual(@as(u32, 2048), fetchRows(&narrow, 2048, 64 << 20));
    var wide_ti = typeInfo(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0);
    wide_ti.clientSizeInBytes = 16000;
    const w = try fromTypeInfo(&wide_ti, .{});
    const wide = [_]Column{ w, w, w, w, w, w, w, w, w, w };
    const n = fetchRows(&wide, 2048, 64 << 20);
    try testing.expect(n < 2048 and n > 300);
    try testing.expectEqual(@as(u32, 1), fetchRows(&wide, 2048, 10));
}

test "timestamp conversion via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    d.value.asTimestamp = mkTs(2024, 2, 29, 13, 45, 30, 123456789, 0, 0);
    const plan = try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP, 0, 0);
    var out: [2]i64 = .{ 0, 0 };
    try store(plan, &d.value, @ptrCast(&out), 1);
    // SELECT epoch_us(TIMESTAMP '2024-02-29 13:45:30.123456') = 1709214330123456
    try testing.expectEqual(@as(i64, 1709214330123456), out[1]);

    // DATE before the epoch
    d.value.asTimestamp = mkTs(1900, 1, 1, 0, 0, 0, 0, 0, 0);
    try store(plan, &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i64, -2208988800000000), out[0]);
}

test "timestamptz conversion applies offset" {
    var d = std.mem.zeroes(c.dpiData);
    // 2024-01-01 10:00:00 +05:30  == 2024-01-01 04:30:00 UTC
    d.value.asTimestamp = mkTs(2024, 1, 1, 10, 0, 0, 0, 5, 30);
    const plan = try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP_TZ, 0, 0);
    var out: [1]i64 = .{0};
    try store(plan, &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i64, 1704083400000000), out[0]);
    // -03:30 offset (both components negative in ODPI-C)
    d.value.asTimestamp = mkTs(2024, 1, 1, 0, 0, 0, 0, -3, -30);
    try store(plan, &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i64, 1704079800000000), out[0]);
}

test "decimal storage widths via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    var text = "-1234.56".*;
    d.value.asBytes = .{ .ptr = &text, .length = text.len, .encoding = null };

    var p = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 6, 2); // int32 storage
    var o32: [1]i32 = .{0};
    try store(p, &d.value, @ptrCast(&o32), 0);
    try testing.expectEqual(@as(i32, -123456), o32[0]);

    p = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 30, 2); // hugeint storage
    var oh: [1]c.duckdb_hugeint = undefined;
    try store(p, &d.value, @ptrCast(&oh), 0);
    try testing.expectEqual(@as(i64, -1), oh[0].upper);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -123456))), oh[0].lower);

    var small = "12.3".*;
    d.value.asBytes = .{ .ptr = &small, .length = small.len, .encoding = null };
    p = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 4, 1); // int16 storage
    var o16: [1]i16 = .{0};
    try store(p, &d.value, @ptrCast(&o16), 0);
    try testing.expectEqual(@as(i16, 123), o16[0]);
}

test "numeric and boolean natives via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    var o64: [1]i64 = .{0};
    d.value.asInt64 = -42;
    try store((try planOf(c.DPI_ORACLE_TYPE_NUMBER, 9, 0)), &d.value, @ptrCast(&o64), 0);
    try testing.expectEqual(@as(i64, -42), o64[0]);

    var of64: [1]f64 = .{0};
    d.value.asDouble = 3.25;
    // the lossy_double fast path takes OCI's own double conversion
    try store((try planWith(c.DPI_ORACLE_TYPE_NUMBER, 0, -127, .lossy_double)), &d.value, @ptrCast(&of64), 0);
    try testing.expectEqual(@as(f64, 3.25), of64[0]);

    var of32: [1]f32 = .{0};
    d.value.asFloat = 1.5;
    try store((try planOf(c.DPI_ORACLE_TYPE_NATIVE_FLOAT, 0, 0)), &d.value, @ptrCast(&of32), 0);
    try testing.expectEqual(@as(f32, 1.5), of32[0]);

    var ob: [1]bool = .{false};
    d.value.asBoolean = 1;
    try store((try planOf(c.DPI_ORACLE_TYPE_BOOLEAN, 0, 0)), &d.value, @ptrCast(&ob), 0);
    try testing.expect(ob[0]);

    // strings are not fixed-width
    try testing.expectError(error.NotFixed, store((try planOf(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0)), &d.value, @ptrCast(&ob), 0));
}

test "interval conversion via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    d.value.asIntervalDS = .{ .days = 3, .hours = 4, .minutes = 5, .seconds = 6, .fseconds = 7_000_000 };
    var out: [1]c.duckdb_interval = undefined;
    try store((try planOf(c.DPI_ORACLE_TYPE_INTERVAL_DS, 0, 0)), &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i32, 3), out[0].days);
    try testing.expectEqual(@as(i64, (4 * 3600 + 5 * 60 + 6) * 1_000_000 + 7_000), out[0].micros);

    d.value.asIntervalYM = .{ .years = 2, .months = 3 };
    try store((try planOf(c.DPI_ORACLE_TYPE_INTERVAL_YM, 0, 0)), &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i32, 27), out[0].months);
}

test "23ai type plans: BOOLEAN, JSON, OSON BLOB, VECTOR" {
    const b = try planOf(c.DPI_ORACLE_TYPE_BOOLEAN, 0, 0);
    try testing.expectEqual(Kind.boolean, b.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_BOOLEAN), b.native_type);

    const j = try planOf(c.DPI_ORACLE_TYPE_JSON, 0, 0);
    try testing.expectEqual(Kind.json, j.kind);
    try testing.expectEqual(@as(c.duckdb_type, c.DUCKDB_TYPE_VARCHAR), j.kind.duckdbType());
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_JSON), j.native_type);

    // BLOB IS JSON (FORMAT OSON) -> JSON text; a plain BLOB stays BLOB (19c behaviour)
    var oson = typeInfo(c.DPI_ORACLE_TYPE_BLOB, 0, 0);
    oson.isOson = 1;
    try testing.expect((try fromTypeInfo(&oson, .{})).kind == .json);
    const plain = try planOf(c.DPI_ORACLE_TYPE_BLOB, 0, 0);
    try testing.expect(plain.kind != .json);
    try testing.expectEqual(Kind.blob, plain.kind);

    const cases = [_]struct { fmt: u8, elem: ListElem }{
        .{ .fmt = c.DPI_VECTOR_FORMAT_FLOAT32, .elem = .float },
        .{ .fmt = c.DPI_VECTOR_FORMAT_FLOAT64, .elem = .double },
        .{ .fmt = c.DPI_VECTOR_FORMAT_INT8, .elem = .float },
        .{ .fmt = c.DPI_VECTOR_FORMAT_BINARY, .elem = .utinyint },
        .{ .fmt = 0, .elem = .double }, // VECTOR(*, *) flexible format
    };
    for (cases) |cs| {
        var ti = typeInfo(c.DPI_ORACLE_TYPE_VECTOR, 0, 0);
        ti.vectorFormat = cs.fmt;
        ti.vectorDimensions = 3;
        const p = try fromTypeInfo(&ti, .{});
        try testing.expectEqual(Kind.list, p.kind);
        try testing.expectEqual(cs.elem, p.list_elem);
        try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_VECTOR), p.native_type);
    }
}

test "BOOLEAN value via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    var out: [2]bool = .{ true, true };
    d.value.asBoolean = 0;
    try store((try planOf(c.DPI_ORACLE_TYPE_BOOLEAN, 0, 0)), &d.value, @ptrCast(&out), 1);
    try testing.expect(!out[1]);
}

test "NumberMode.parse" {
    try testing.expectEqual(NumberMode.double, NumberMode.parse("double").?);
    try testing.expectEqual(NumberMode.lossy_double, NumberMode.parse("LOSSY_DOUBLE").?);
    try testing.expectEqual(NumberMode.varchar, NumberMode.parse("Varchar").?);
    try testing.expect(NumberMode.parse("decimal") == null);
}

test "unconstrained NUMBER follows the number mode; exact types never do" {
    const N = c.DPI_ORACLE_TYPE_NUMBER;
    // default: checked double, fetched as text
    const d = try planWith(N, 0, -127, .double);
    try testing.expectEqual(Kind.number_double, d.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_BYTES), d.native_type);
    try testing.expectEqual(@as(c.duckdb_type, c.DUCKDB_TYPE_DOUBLE), d.kind.duckdbType());
    // lossy: the old fast path
    const l = try planWith(N, 0, -127, .lossy_double);
    try testing.expectEqual(Kind.double, l.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_DOUBLE), l.native_type);
    // varchar: exact text
    const v = try planWith(N, 0, -127, .varchar);
    try testing.expectEqual(Kind.varchar, v.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_BYTES), v.native_type);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, N), v.oracle_type);
    // FLOAT(b) and NUMBER wider than DECIMAL(38) take the same path
    try testing.expectEqual(Kind.number_double, (try planWith(N, 126, -127, .double)).kind);
    try testing.expectEqual(Kind.number_double, (try planWith(N, 38, -5, .double)).kind);
    try testing.expectEqual(Kind.varchar, (try planWith(N, 50, 10, .varchar)).kind);
    // exact types are unaffected by the mode
    try testing.expectEqual(Kind.bigint, (try planWith(N, 10, 0, .varchar)).kind);
    try testing.expectEqual(Kind.decimal, (try planWith(N, 10, 2, .varchar)).kind);
    try testing.expectEqual(Kind.double, (try planWith(c.DPI_ORACLE_TYPE_NATIVE_DOUBLE, 0, 0, .varchar)).kind);
}

test "number_double column stores doubles and rejects lossy integers" {
    const plan = try planWith(c.DPI_ORACLE_TYPE_NUMBER, 0, -127, .double);
    var d = std.mem.zeroes(c.dpiData);
    var text = "123.5".*;
    d.value.asBytes = .{ .ptr = &text, .length = text.len, .encoding = null };
    var out: [2]f64 = .{ 0, 0 };
    try store(plan, &d.value, @ptrCast(&out), 1);
    try testing.expectEqual(@as(f64, 123.5), out[1]);

    var big = "9007199254740993".*;
    d.value.asBytes = .{ .ptr = &big, .length = big.len, .encoding = null };
    try testing.expectError(error.PrecisionLoss, store(plan, &d.value, @ptrCast(&out), 0));
    try testing.expectEqual(@as(f64, 0), out[0]); // nothing was written
}

test "varchar-mode number needs the full NUMBER text buffer in the batch budget" {
    const plan = try planWith(c.DPI_ORACLE_TYPE_NUMBER, 0, -127, .varchar);
    try testing.expect(plan.bufferBytes() >= 172);
}

// --- write(): every kind through the vector-sink and handle-reader seams -------

const MemSink = struct {
    buf: [16 * 8]u8 align(16) = undefined,
    valid: [8]bool = @splat(true),
    strs: [8]?[]u8 = @splat(null),
    list_len: u64 = 0,
    child: [64]u8 align(16) = undefined,
    child_cap: u64 = 16, // elements
    reserve_calls: u32 = 0,

    pub fn data(self: *MemSink) [*]u8 {
        return &self.buf;
    }
    pub fn setNull(self: *MemSink, row: u32) void {
        self.valid[row] = false;
    }
    pub fn string(self: *MemSink, row: u32, bytes: []const u8) void {
        self.strs[row] = testing.allocator.dupe(u8, bytes) catch unreachable;
    }
    pub fn listSize(self: *MemSink) u64 {
        return self.list_len;
    }
    pub fn listReserve(self: *MemSink, total: u64) bool {
        self.reserve_calls += 1;
        return total <= self.child_cap;
    }
    pub fn listChildData(self: *MemSink) ?[*]u8 {
        return &self.child;
    }
    pub fn listSetSize(self: *MemSink, n: u64) void {
        self.list_len = n;
    }
    fn deinit(self: *MemSink) void {
        for (self.strs) |s| if (s) |x| testing.allocator.free(x);
    }
};

const FakeReader = struct {
    vec: ?c.dpiVectorInfo = null,
    json: ?*const c.dpiJsonNode = null,
    rowid: ?[]const u8 = null,

    pub fn readVector(self: FakeReader, handle: ?*c.dpiVector, info: *c.dpiVectorInfo) error{Failed}!void {
        _ = handle;
        info.* = self.vec orelse return error.Failed;
    }
    pub fn readJson(self: FakeReader, handle: ?*c.dpiJson) error{Failed}!*const c.dpiJsonNode {
        _ = handle;
        return self.json orelse error.Failed;
    }
    pub fn readRowid(self: FakeReader, handle: ?*c.dpiRowid) error{Failed}![]const u8 {
        _ = handle;
        return self.rowid orelse error.Failed;
    }
};

fn writeOne(col: *const Column, sink: *MemSink, reader: FakeReader, row: u32, d: *const c.dpiData) Column.WriteError!void {
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(testing.allocator);
    return col.write(sink, reader, .{ .gpa = testing.allocator, .json_buf = &json_buf }, row, d);
}

fn dataInt(v: i64) c.dpiData {
    var d = std.mem.zeroes(c.dpiData);
    d.value.asInt64 = v;
    return d;
}

fn dataNull() c.dpiData {
    var d = std.mem.zeroes(c.dpiData);
    d.isNull = 1;
    return d;
}

test "write: NULLs mark the row invalid and leave other rows intact" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 10, 0); // BIGINT
    try writeOne(&col, &sink, .{}, 0, &dataInt(5));
    try writeOne(&col, &sink, .{}, 1, &dataNull());
    try writeOne(&col, &sink, .{}, 2, &dataInt(-7));
    const out: [*]const i64 = @ptrCast(@alignCast(&sink.buf));
    try testing.expectEqual(@as(i64, 5), out[0]);
    try testing.expectEqual(@as(i64, -7), out[2]);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, sink.valid[0..3]);
}

test "write: strings keep UTF-8 and empty values; a null pointer is the empty string" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0);
    var d = std.mem.zeroes(c.dpiData);
    var text = "gr\xc3\xbc\xc3\x9fe \xe2\x82\xac".*; // "grüße €"
    d.value.asBytes = .{ .ptr = &text, .length = text.len, .encoding = null };
    try writeOne(&col, &sink, .{}, 0, &d);
    d.value.asBytes = .{ .ptr = null, .length = 0, .encoding = null };
    try writeOne(&col, &sink, .{}, 1, &d);
    try testing.expectEqualStrings("gr\xc3\xbc\xc3\x9fe \xe2\x82\xac", sink.strs[0].?);
    try testing.expectEqualStrings("", sink.strs[1].?);
}

test "write: DECIMAL goes through the width-dependent storage" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 10, 2); // DECIMAL(10,2): int64 storage
    var d = std.mem.zeroes(c.dpiData);
    var text = "-1234.56".*;
    d.value.asBytes = .{ .ptr = &text, .length = text.len, .encoding = null };
    try writeOne(&col, &sink, .{}, 1, &d);
    const out: [*]const i64 = @ptrCast(@alignCast(&sink.buf));
    try testing.expectEqual(@as(i64, -123456), out[1]);
}

test "write: ROWID text comes from the handle reader" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_ROWID, 0, 0);
    try writeOne(&col, &sink, .{ .rowid = "AAAR3sAAEAAAACXAAA" }, 0, &dataInt(0));
    try testing.expectEqualStrings("AAAR3sAAEAAAACXAAA", sink.strs[0].?);
    try testing.expectError(error.ReadRowid, writeOne(&col, &sink, .{}, 1, &dataInt(0)));
}

test "write: JSON tree becomes JSON text through the reader" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_JSON, 0, 0);
    var num = std.mem.zeroes(c.dpiDataBuffer);
    var txt = "123.45".*;
    num.asBytes = .{ .ptr = &txt, .length = txt.len, .encoding = null };
    const node: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NUMBER, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &num };
    try writeOne(&col, &sink, .{ .json = &node }, 0, &dataInt(0));
    try testing.expectEqualStrings("123.45", sink.strs[0].?);
    try testing.expectError(error.ReadJson, writeOne(&col, &sink, .{}, 1, &dataInt(0)));
}

fn vectorInfo(vals: []f32) c.dpiVectorInfo {
    var vi = std.mem.zeroes(c.dpiVectorInfo);
    vi.format = c.DPI_VECTOR_FORMAT_FLOAT32;
    vi.numDimensions = @intCast(vals.len);
    vi.dimensionSize = 4;
    vi.dimensions.asPtr = vals.ptr;
    return vi;
}

test "write: VECTOR rows become LIST entries with running offsets; NULL rows are empty entries" {
    var sink: MemSink = .{};
    defer sink.deinit();
    var ti = typeInfo(c.DPI_ORACLE_TYPE_VECTOR, 0, 0);
    ti.vectorFormat = c.DPI_VECTOR_FORMAT_FLOAT32;
    const col = try fromTypeInfo(&ti, .{});
    var a = [_]f32{ 1.5, 2.5 };
    var b = [_]f32{3.25};
    try writeOne(&col, &sink, .{ .vec = vectorInfo(&a) }, 0, &dataInt(0));
    try writeOne(&col, &sink, .{}, 1, &dataNull());
    try writeOne(&col, &sink, .{ .vec = vectorInfo(&b) }, 2, &dataInt(0));
    const entries: [*]const c.duckdb_list_entry = @ptrCast(@alignCast(&sink.buf));
    try testing.expectEqual(@as(u64, 0), entries[0].offset);
    try testing.expectEqual(@as(u64, 2), entries[0].length);
    try testing.expectEqual(@as(u64, 2), entries[1].offset); // NULL: empty entry at the current end
    try testing.expectEqual(@as(u64, 0), entries[1].length);
    try testing.expectEqual(@as(u64, 2), entries[2].offset);
    try testing.expectEqual(@as(u64, 1), entries[2].length);
    try testing.expectEqual(@as(u64, 3), sink.list_len);
    const child: [*]const f32 = @ptrCast(@alignCast(&sink.child));
    try testing.expectEqualSlices(f32, &.{ 1.5, 2.5, 3.25 }, child[0..3]);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, sink.valid[0..3]);
}

test "write: a failed child reserve is an error, not a write past the buffer" {
    var sink: MemSink = .{ .child_cap = 1 };
    defer sink.deinit();
    var ti = typeInfo(c.DPI_ORACLE_TYPE_VECTOR, 0, 0);
    ti.vectorFormat = c.DPI_VECTOR_FORMAT_FLOAT32;
    const col = try fromTypeInfo(&ti, .{});
    var a = [_]f32{ 1.5, 2.5 };
    try testing.expectError(error.ListReserve, writeOne(&col, &sink, .{ .vec = vectorInfo(&a) }, 0, &dataInt(0)));
    try testing.expectEqual(@as(u64, 0), sink.list_len);
}

test "write: a lossy NUMBER-as-DOUBLE integer is an error and writes nothing" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 0, -127);
    var d = std.mem.zeroes(c.dpiData);
    var text = "9007199254740993".*;
    d.value.asBytes = .{ .ptr = &text, .length = text.len, .encoding = null };
    @memset(&sink.buf, 0);
    try testing.expectError(error.PrecisionLoss, writeOne(&col, &sink, .{}, 0, &d));
    try testing.expectEqual(@as(u8, 0), sink.buf[0]);
}

// --- review F5: INTERVAL YEAR(9) TO MONTH must not abort the process -----------

test "write: INTERVAL YEAR TO MONTH at the i32 months limit, and beyond it" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_INTERVAL_YM, 0, 0);
    var d = std.mem.zeroes(c.dpiData);
    // 178956970 years * 12 + 7 months = 2147483647 = maxInt(i32)
    d.value.asIntervalYM = .{ .years = 178956970, .months = 7 };
    try writeOne(&col, &sink, .{}, 0, &d);
    const out: [*]const c.duckdb_interval = @ptrCast(@alignCast(&sink.buf));
    try testing.expectEqual(@as(i32, 2147483647), out[0].months);
    // one month more does not fit a DuckDB INTERVAL: error, not a panic
    d.value.asIntervalYM = .{ .years = 178956970, .months = 8 };
    try testing.expectError(error.IntervalOverflow, writeOne(&col, &sink, .{}, 1, &d));
    // Oracle allows 999999999 years
    d.value.asIntervalYM = .{ .years = 999999999, .months = 11 };
    try testing.expectError(error.IntervalOverflow, writeOne(&col, &sink, .{}, 1, &d));
    d.value.asIntervalYM = .{ .years = -178956970, .months = -8 };
    try testing.expectEqual(@as(i32, -2147483648), blk: {
        try writeOne(&col, &sink, .{}, 2, &d);
        break :blk out[2].months;
    });
    d.value.asIntervalYM = .{ .years = -178956970, .months = -9 };
    try testing.expectError(error.IntervalOverflow, writeOne(&col, &sink, .{}, 2, &d));
}

// --- review F6: LOB columns must not be budgeted at 64 KiB per row -------------

test "fetch batch sizing assumes LOB values are large" {
    const clob = try planOf(c.DPI_ORACLE_TYPE_CLOB, 0, 0);
    const one = [_]Column{clob};
    // 64 MiB budget / (1 MiB + overhead) rows: far fewer than a 2048-row vector
    try testing.expect(fetchRows(&one, 2048, 64 << 20) <= 64);
    try testing.expect(fetchRows(&one, 2048, 64 << 20) >= 32);
    const two = [_]Column{ clob, clob };
    try testing.expect(fetchRows(&two, 2048, 64 << 20) <= 32);
    const blob = try planOf(c.DPI_ORACLE_TYPE_BLOB, 0, 0);
    try testing.expect(fetchRows(&[_]Column{blob}, 2048, 64 << 20) <= 64);
    const xml = try planOf(c.DPI_ORACLE_TYPE_XMLTYPE, 0, 0);
    try testing.expect(fetchRows(&[_]Column{xml}, 2048, 64 << 20) <= 64);
    // narrow rows still use a full DuckDB vector
    const narrow = [_]Column{ try planOf(c.DPI_ORACLE_TYPE_NUMBER, 10, 0), try planOf(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0) };
    try testing.expectEqual(@as(u32, 2048), fetchRows(&narrow, 2048, 64 << 20));
}

test "logicalSpec describes the DuckDB type without calling DuckDB" {
    const dec = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 12, 3);
    const s = dec.logicalSpec();
    try testing.expectEqual(@as(c.duckdb_type, c.DUCKDB_TYPE_DECIMAL), s.id);
    try testing.expectEqual(@as(u8, 12), s.width);
    try testing.expectEqual(@as(u8, 3), s.scale);
    var ti = typeInfo(c.DPI_ORACLE_TYPE_VECTOR, 0, 0);
    ti.vectorFormat = c.DPI_VECTOR_FORMAT_BINARY;
    const lst = (try fromTypeInfo(&ti, .{})).logicalSpec();
    try testing.expectEqual(@as(c.duckdb_type, c.DUCKDB_TYPE_LIST), lst.id);
    try testing.expectEqual(@as(c.duckdb_type, c.DUCKDB_TYPE_UTINYINT), lst.child.?);
    try testing.expectEqual(@as(c.duckdb_type, c.DUCKDB_TYPE_VARCHAR), (try planOf(c.DPI_ORACLE_TYPE_ROWID, 0, 0)).logicalSpec().id);
}

test "write: the JSON scratch buffer is reused across rows without leaking the previous row" {
    var sink: MemSink = .{};
    defer sink.deinit();
    const col = try planOf(c.DPI_ORACLE_TYPE_JSON, 0, 0);
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(testing.allocator);
    const ctx: Column.WriteCtx = .{ .gpa = testing.allocator, .json_buf = &json_buf };

    var long_v = std.mem.zeroes(c.dpiDataBuffer);
    var long_t = "1234567890.5".*;
    long_v.asBytes = .{ .ptr = &long_t, .length = long_t.len, .encoding = null };
    const long_node: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NUMBER, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &long_v };
    var short_v = std.mem.zeroes(c.dpiDataBuffer);
    var short_t = "7".*;
    short_v.asBytes = .{ .ptr = &short_t, .length = short_t.len, .encoding = null };
    const short_node: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NUMBER, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &short_v };

    try col.write(&sink, FakeReader{ .json = &long_node }, ctx, 0, &dataInt(0));
    try col.write(&sink, FakeReader{ .json = &short_node }, ctx, 1, &dataInt(0));
    try testing.expectEqualStrings("1234567890.5", sink.strs[0].?);
    try testing.expectEqualStrings("7", sink.strs[1].?);
}
