//! Oracle -> DuckDB type planning and value conversion.
//!
//! Everything in here is pure (no DuckDB API calls, no OCI calls) so it can be
//! unit-tested with hand-built ODPI-C `dpiDataTypeInfo` / `dpiData` values:
//! `zig build test`.
const std = @import("std");
const c = @import("c.zig").c;

/// The DuckDB type a column is materialised as.
pub const DuckKind = enum {
    bigint,
    decimal,
    double,
    float,
    boolean,
    /// DOUBLE fetched as NUMBER text and checked for silent integer rounding
    number_double,
    varchar,
    blob,
    timestamp,
    timestamptz,
    interval,
    /// LIST of `ColumnPlan.list_elem` (Oracle 23ai+ VECTOR)
    list,

    pub fn duckdbType(self: DuckKind) c.duckdb_type {
        return switch (self) {
            .bigint => c.DUCKDB_TYPE_BIGINT,
            .decimal => c.DUCKDB_TYPE_DECIMAL,
            .double, .number_double => c.DUCKDB_TYPE_DOUBLE,
            .float => c.DUCKDB_TYPE_FLOAT,
            .boolean => c.DUCKDB_TYPE_BOOLEAN,
            .varchar => c.DUCKDB_TYPE_VARCHAR,
            .blob => c.DUCKDB_TYPE_BLOB,
            .timestamp => c.DUCKDB_TYPE_TIMESTAMP,
            .timestamptz => c.DUCKDB_TYPE_TIMESTAMP_TZ,
            .interval => c.DUCKDB_TYPE_INTERVAL,
            .list => c.DUCKDB_TYPE_LIST,
        };
    }
};

/// How to define (fetch) one Oracle column and what to turn it into.
pub const ColumnPlan = struct {
    kind: DuckKind,
    /// DECIMAL width/scale (only for .decimal)
    width: u8 = 0,
    scale: u8 = 0,
    /// arguments for dpiConn_newVar()
    oracle_type: c.dpiOracleTypeNum,
    native_type: c.dpiNativeTypeNum,
    size: u32 = 0,
    size_is_bytes: bool = true,
    /// value is a dpiRowid handle that must be turned into text
    is_rowid: bool = false,
    /// value is a dpiJson handle that is serialised to JSON text (23ai+ JSON)
    is_json: bool = false,
    /// element type of a .list column (VECTOR)
    list_elem: ListElem = .double,
};

/// Element types used for VECTOR columns.
pub const ListElem = enum {
    float,
    double,
    utinyint,

    pub fn duckdbType(self: ListElem) c.duckdb_type {
        return switch (self) {
            .float => c.DUCKDB_TYPE_FLOAT,
            .double => c.DUCKDB_TYPE_DOUBLE,
            .utinyint => c.DUCKDB_TYPE_UTINYINT,
        };
    }

    pub fn size(self: ListElem) usize {
        return switch (self) {
            .float => 4,
            .double => 8,
            .utinyint => 1,
        };
    }
};

pub const PlanError = error{UnsupportedType};

/// Largest precision for which NUMBER(p,0) becomes BIGINT.
pub const max_bigint_precision = 18;
/// DuckDB's maximum DECIMAL width.
pub const max_decimal_width = 38;

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
        inline for (@typeInfo(NumberMode).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(text, f.name)) return @field(NumberMode, f.name);
        }
        return null;
    }
};

pub const PlanOptions = struct { number: NumberMode = .double };

/// Decide the DuckDB type and the ODPI-C define parameters for a column.
pub fn planColumn(ti: *const c.dpiDataTypeInfo) PlanError!ColumnPlan {
    return planColumnOpts(ti, .{});
}

pub fn planColumnOpts(ti: *const c.dpiDataTypeInfo, opts: PlanOptions) PlanError!ColumnPlan {
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
        c.DPI_ORACLE_TYPE_ROWID, c.DPI_ORACLE_TYPE_UROWID => return .{ .kind = .varchar, .oracle_type = c.DPI_ORACLE_TYPE_ROWID, .native_type = c.DPI_NATIVE_TYPE_ROWID, .is_rowid = true },

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

fn jsonPlan() ColumnPlan {
    return .{ .kind = .varchar, .oracle_type = c.DPI_ORACLE_TYPE_JSON, .native_type = c.DPI_NATIVE_TYPE_JSON, .is_json = true };
}

/// VECTOR(n, FLOAT32) -> FLOAT[], FLOAT64 -> DOUBLE[], INT8 -> FLOAT[] (exact),
/// BINARY -> UTINYINT[] (the packed bytes, n/8 elements), flexible (*) -> DOUBLE[].
pub fn vectorElem(format: u8) ListElem {
    return switch (format) {
        c.DPI_VECTOR_FORMAT_FLOAT32, c.DPI_VECTOR_FORMAT_INT8 => .float,
        c.DPI_VECTOR_FORMAT_BINARY => .utinyint,
        else => .double,
    };
}

fn planNumber(precision: i16, scale: i8, mode: NumberMode) ColumnPlan {
    const ot = c.DPI_ORACLE_TYPE_NUMBER;
    // Fallback for NUMBERs with no exact DECIMAL form (see NumberMode).
    const dbl: ColumnPlan = switch (mode) {
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
        if (digits <= max_decimal_width)
            return .{ .kind = .decimal, .width = @intCast(digits), .scale = 0, .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES };
        return dbl;
    }
    // NUMBER(p,s), s>0. Oracle allows s > p (e.g. NUMBER(2,5) = 0.000dd).
    const width = @max(p, s);
    if (width <= max_decimal_width)
        return .{ .kind = .decimal, .width = @intCast(width), .scale = @intCast(s), .oracle_type = ot, .native_type = c.DPI_NATIVE_TYPE_BYTES };
    return dbl;
}

/// Approximate per-row fetch buffer bytes ODPI-C allocates for a column.
pub fn rowBufferBytes(plan: *const ColumnPlan) u64 {
    const overhead: u64 = 24; // dpiData + indicator/length/return code
    // NUMBER fetched as text: ODPI-C allocates DPI_NUMBER_AS_TEXT_CHARS per row
    if (plan.kind == .decimal or plan.kind == .number_double or
        (plan.oracle_type == c.DPI_ORACLE_TYPE_NUMBER and plan.native_type == c.DPI_NATIVE_TYPE_BYTES)) return overhead + 172;
    if (plan.is_json or plan.kind == .list) return overhead + 256; // descriptor; value materialised per row
    // dynamic (LONG / LOB-as-LONG) buffers grow on demand; count a nominal chunk
    if (plan.oracle_type == c.DPI_ORACLE_TYPE_LONG_VARCHAR or plan.oracle_type == c.DPI_ORACLE_TYPE_LONG_NVARCHAR or
        plan.oracle_type == c.DPI_ORACLE_TYPE_LONG_RAW or plan.oracle_type == c.DPI_ORACLE_TYPE_XMLTYPE) return overhead + 64 * 1024;
    return overhead + @max(plan.size, 16);
}

/// Rows per fetch: a full DuckDB vector unless the fetch buffers for one batch
/// would exceed `budget` bytes (very wide rows, e.g. many VARCHAR2(4000 CHAR)
/// columns in an AL32UTF8 database), in which case fewer rows are fetched per
/// DuckDB chunk. Always at least 1.
pub fn fetchRows(plans: []const ColumnPlan, vector_size: u32, budget: u64) u32 {
    var row: u64 = 0;
    for (plans) |*p| row += rowBufferBytes(p);
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
// Value conversion
// ---------------------------------------------------------------------------

const us_per_sec: i64 = 1_000_000;
const us_per_day: i64 = 86_400 * us_per_sec;

/// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
pub fn daysFromCivil(year: i32, month: u32, day: u32) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const m: i64 = month;
    const mp: i64 = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Oracle DATE / TIMESTAMP -> DuckDB TIMESTAMP (microseconds since epoch, no zone).
/// Fractional nanoseconds are truncated to microseconds.
pub fn timestampMicros(ts: *const c.dpiTimestamp) i64 {
    const days = daysFromCivil(ts.year, ts.month, ts.day);
    const secs: i64 = @as(i64, ts.hour) * 3600 + @as(i64, ts.minute) * 60 + @as(i64, ts.second);
    return days * us_per_day + secs * us_per_sec + @divTrunc(@as(i64, ts.fsecond), 1000);
}

/// Oracle TIMESTAMP WITH (LOCAL) TIME ZONE -> DuckDB TIMESTAMPTZ (UTC micros).
/// ODPI-C returns the local wall-clock time plus the zone offset; UTC = local - offset.
pub fn timestampTzMicros(ts: *const c.dpiTimestamp) i64 {
    const offset_min: i64 = @as(i64, ts.tzHourOffset) * 60 + @as(i64, ts.tzMinuteOffset);
    return timestampMicros(ts) - offset_min * 60 * us_per_sec;
}

pub fn intervalDS(iv: *const c.dpiIntervalDS) c.duckdb_interval {
    const micros: i64 = (@as(i64, iv.hours) * 3600 + @as(i64, iv.minutes) * 60 + @as(i64, iv.seconds)) * us_per_sec +
        @divTrunc(@as(i64, iv.fseconds), 1000);
    return .{ .months = 0, .days = iv.days, .micros = micros };
}

pub fn intervalYM(iv: *const c.dpiIntervalYM) c.duckdb_interval {
    return .{ .months = iv.years * 12 + iv.months, .days = 0, .micros = 0 };
}

pub const DecimalError = error{ InvalidNumber, DecimalOverflow };

pub const NumberDoubleError = error{ InvalidNumber, PrecisionLoss };

/// Convert ODPI-C NUMBER text ("-123.45", "1000", ".5") to a double. An integral
/// value of up to 38 digits that a double cannot represent exactly is rejected
/// with error.PrecisionLoss rather than silently rounded (9007199254740993 would
/// otherwise become 9007199254740992). Fractions are inherently approximate in a
/// DOUBLE and numbers of more than 38 digits are floating-point magnitudes, so
/// both are accepted.
pub fn parseNumberAsDouble(text: []const u8) NumberDoubleError!f64 {
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        negative = text[i] == '-';
        i += 1;
    }
    var int_digits: u32 = 0; // significant integer digits (leading zeros skipped)
    var acc: u128 = 0; // valid while int_digits <= max_decimal_width
    var seen_point = false;
    var seen_digit = false;
    var fraction_nonzero = false;
    for (text[i..]) |ch| {
        if (ch == '.') {
            if (seen_point) return error.InvalidNumber;
            seen_point = true;
            continue;
        }
        if (ch < '0' or ch > '9') return error.InvalidNumber;
        seen_digit = true;
        if (seen_point) {
            if (ch != '0') fraction_nonzero = true;
        } else if (int_digits > 0 or ch != '0') {
            int_digits += 1;
            if (int_digits <= max_decimal_width) acc = acc * 10 + (ch - '0');
        }
    }
    if (!seen_digit) return error.InvalidNumber;

    const magnitude: f64 = blk: {
        if (fraction_nonzero or int_digits > max_decimal_width) {
            // approximate by nature: a fraction, or a floating-point sized magnitude
            var buf: [DPI_NUMBER_TEXT_MAX]u8 = undefined;
            const digits = text[i..];
            if (digits.len + 1 > buf.len) return error.InvalidNumber;
            const prefix: usize = if (digits[0] == '.') 1 else 0; // "0" before a leading point
            if (prefix == 1) buf[0] = '0';
            @memcpy(buf[prefix .. prefix + digits.len], digits);
            break :blk std.fmt.parseFloat(f64, buf[0 .. prefix + digits.len]) catch return error.InvalidNumber;
        }
        // integral, at most 38 digits: must survive the round trip through f64
        const as_double: f64 = @floatFromInt(acc);
        if (as_double >= 3.4e38 or @as(u128, @intFromFloat(as_double)) != acc) return error.PrecisionLoss;
        break :blk as_double;
    };
    return if (negative) -magnitude else magnitude;
}

/// ODPI-C renders a NUMBER as at most this many characters (DPI_NUMBER_AS_TEXT_CHARS).
const DPI_NUMBER_TEXT_MAX = 173;

/// Parse ODPI-C's NUMBER-as-text output ("-123.45", "0.001", "1000") into the
/// unscaled integer of a DECIMAL(width, scale). Extra fractional digits are
/// rounded half away from zero (Oracle already enforces the column scale, so
/// this only matters for defensive robustness).
pub fn parseDecimal(text: []const u8, width: u8, scale: u8) DecimalError!i128 {
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        negative = text[i] == '-';
        i += 1;
    }
    var acc: i128 = 0;
    var digits: u32 = 0; // significant digits accumulated (excluding leading zeros)
    var frac_digits: u32 = 0;
    var seen_point = false;
    var seen_digit = false;
    var round_up = false;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '.') {
            if (seen_point) return error.InvalidNumber;
            seen_point = true;
            continue;
        }
        if (ch < '0' or ch > '9') return error.InvalidNumber;
        seen_digit = true;
        const d: i128 = ch - '0';
        if (seen_point) {
            if (frac_digits == scale) {
                // the first dropped digit decides rounding; validate the rest
                round_up = d >= 5;
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] < '0' or text[i] > '9') return error.InvalidNumber;
                }
                break;
            }
            frac_digits += 1;
        }
        if (acc != 0 or d != 0) digits += 1;
        if (digits > max_decimal_width) return error.DecimalOverflow;
        acc = acc * 10 + d;
    }
    if (!seen_digit) return error.InvalidNumber;
    while (frac_digits < scale) : (frac_digits += 1) {
        const m = @mulWithOverflow(acc, 10);
        if (m[1] != 0) return error.DecimalOverflow;
        acc = m[0];
    }
    if (round_up) acc += 1;
    if (acc >= pow10(width)) return error.DecimalOverflow;
    return if (negative) -acc else acc;
}

fn pow10(n: u8) i128 {
    var r: i128 = 1;
    var k: u8 = 0;
    while (k < n) : (k += 1) r *= 10;
    return r;
}

/// Byte size of DuckDB's physical storage for a DECIMAL of the given width.
pub fn decimalStorageSize(width: u8) usize {
    return if (width <= 4) 2 else if (width <= 9) 4 else if (width <= 18) 8 else 16;
}

/// Store an unscaled decimal value into a DuckDB vector data buffer.
pub fn storeDecimal(data: [*]u8, row: usize, width: u8, value: i128) void {
    switch (decimalStorageSize(width)) {
        2 => @as([*]i16, @ptrCast(@alignCast(data)))[row] = @intCast(value),
        4 => @as([*]i32, @ptrCast(@alignCast(data)))[row] = @intCast(value),
        8 => @as([*]i64, @ptrCast(@alignCast(data)))[row] = @intCast(value),
        else => {
            const u: u128 = @bitCast(value);
            @as([*]c.duckdb_hugeint, @ptrCast(@alignCast(data)))[row] = .{
                .lower = @truncate(u),
                .upper = @bitCast(@as(u64, @truncate(u >> 64))),
            };
        },
    }
}

/// Kinds that are written directly into the vector's data buffer (everything
/// except strings/blobs which go through duckdb_vector_assign_string_element_len).
pub const FixedError = DecimalError || NumberDoubleError || error{NotFixed};

/// Convert one non-NULL ODPI-C value of a fixed-width kind and store it at `row`.
pub fn storeFixed(plan: *const ColumnPlan, value: *const c.dpiDataBuffer, data: [*]u8, row: usize) FixedError!void {
    switch (plan.kind) {
        .bigint => @as([*]i64, @ptrCast(@alignCast(data)))[row] = value.asInt64,
        .double => @as([*]f64, @ptrCast(@alignCast(data)))[row] = value.asDouble,
        .float => @as([*]f32, @ptrCast(@alignCast(data)))[row] = value.asFloat,
        .boolean => @as([*]bool, @ptrCast(@alignCast(data)))[row] = value.asBoolean != 0,
        .number_double => {
            const b = value.asBytes;
            const text: []const u8 = if (b.length == 0) "" else b.ptr[0..b.length];
            @as([*]f64, @ptrCast(@alignCast(data)))[row] = try parseNumberAsDouble(text);
        },
        .timestamp => @as([*]i64, @ptrCast(@alignCast(data)))[row] = timestampMicros(&value.asTimestamp),
        .timestamptz => @as([*]i64, @ptrCast(@alignCast(data)))[row] = timestampTzMicros(&value.asTimestamp),
        .interval => @as([*]c.duckdb_interval, @ptrCast(@alignCast(data)))[row] =
            if (plan.native_type == c.DPI_NATIVE_TYPE_INTERVAL_YM) intervalYM(&value.asIntervalYM) else intervalDS(&value.asIntervalDS),
        .decimal => {
            const b = value.asBytes;
            const text: []const u8 = if (b.length == 0) "" else b.ptr[0..b.length];
            storeDecimal(data, row, plan.width, try parseDecimal(text, plan.width, plan.scale));
        },
        .varchar, .blob, .list => return error.NotFixed,
    }
}

// ---------------------------------------------------------------------------
// JSON (Oracle 23ai+ native JSON / OSON) -> JSON text
// ---------------------------------------------------------------------------

pub const JsonError = error{ OutOfMemory, UnsupportedJsonNode, JsonTooDeep };

/// Options for dpiJson_getValue(): numbers as exact decimal text.
pub const json_get_options: u32 = c.DPI_JSON_OPT_NUMBER_AS_STRING;

const max_json_depth = 1000;

/// Serialise an ODPI-C JSON node tree (as returned by dpiJson_getValue) to
/// compact JSON text. Mirrors JSON_SERIALIZE conventions where JSON has no
/// native representation: RAW -> uppercase hex string, DATE/TIMESTAMP -> ISO
/// 8601 string, INTERVAL -> ISO 8601 duration string, non-finite floats ->
/// "Infinity" / "-Infinity" / "NaN" strings.
pub fn serializeJson(gpa: std.mem.Allocator, out: *std.ArrayList(u8), node: *const c.dpiJsonNode) JsonError!void {
    return serializeNode(gpa, out, node, 0);
}

fn bytesOf(b: c.dpiBytes) []const u8 {
    return if (b.ptr == null or b.length == 0) "" else b.ptr[0..b.length];
}

fn serializeNode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), node: *const c.dpiJsonNode, depth: u32) JsonError!void {
    if (depth > max_json_depth) return error.JsonTooDeep;
    if (node.nativeTypeNum == c.DPI_NATIVE_TYPE_NULL or node.oracleTypeNum == c.DPI_ORACLE_TYPE_NONE) {
        return out.appendSlice(gpa, "null");
    }
    const v: *const c.dpiDataBuffer = node.value orelse return out.appendSlice(gpa, "null");
    switch (node.nativeTypeNum) {
        c.DPI_NATIVE_TYPE_JSON_OBJECT => {
            const obj = v.asJsonObject;
            try out.append(gpa, '{');
            if (obj.numFields > 0 and (obj.fields == null or obj.fieldNames == null or obj.fieldNameLengths == null)) return error.UnsupportedJsonNode;
            var i: u32 = 0;
            while (i < obj.numFields) : (i += 1) {
                if (i > 0) try out.append(gpa, ',');
                const name: []const u8 = if (obj.fieldNames[i] == null) "" else obj.fieldNames[i][0..obj.fieldNameLengths[i]];
                try writeJsonString(gpa, out, name);
                try out.append(gpa, ':');
                const fields: [*]const c.dpiJsonNode = @ptrCast(obj.fields);
                try serializeNode(gpa, out, &fields[i], depth + 1);
            }
            try out.append(gpa, '}');
        },
        c.DPI_NATIVE_TYPE_JSON_ARRAY => {
            const arr = v.asJsonArray;
            try out.append(gpa, '[');
            if (arr.numElements > 0 and arr.elements == null) return error.UnsupportedJsonNode;
            var i: u32 = 0;
            while (i < arr.numElements) : (i += 1) {
                if (i > 0) try out.append(gpa, ',');
                const elems: [*]const c.dpiJsonNode = @ptrCast(arr.elements);
                try serializeNode(gpa, out, &elems[i], depth + 1);
            }
            try out.append(gpa, ']');
        },
        c.DPI_NATIVE_TYPE_BYTES => {
            const b = bytesOf(v.asBytes);
            switch (node.oracleTypeNum) {
                c.DPI_ORACLE_TYPE_NUMBER => try out.appendSlice(gpa, if (b.len == 0) "0" else b),
                c.DPI_ORACLE_TYPE_VARCHAR => try writeJsonString(gpa, out, b),
                // RAW, JSON_ID, VECTOR image: hex string
                else => {
                    try out.append(gpa, '"');
                    for (b) |byte| try out.print(gpa, "{X:0>2}", .{byte});
                    try out.append(gpa, '"');
                },
            }
        },
        c.DPI_NATIVE_TYPE_DOUBLE => try writeJsonFloat(gpa, out, v.asDouble),
        c.DPI_NATIVE_TYPE_FLOAT => try writeJsonFloat(gpa, out, v.asFloat),
        c.DPI_NATIVE_TYPE_INT64 => try out.print(gpa, "{d}", .{v.asInt64}),
        c.DPI_NATIVE_TYPE_UINT64 => try out.print(gpa, "{d}", .{v.asUint64}),
        c.DPI_NATIVE_TYPE_BOOLEAN => try out.appendSlice(gpa, if (v.asBoolean != 0) "true" else "false"),
        c.DPI_NATIVE_TYPE_TIMESTAMP => {
            const ts = v.asTimestamp;
            try out.print(gpa, "\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u16, @intCast(@max(ts.year, 0))), ts.month, ts.day, ts.hour, ts.minute, ts.second });
            if (ts.fsecond != 0) {
                if (ts.fsecond % 1000 == 0) try out.print(gpa, ".{d:0>6}", .{ts.fsecond / 1000}) else try out.print(gpa, ".{d:0>9}", .{ts.fsecond});
            }
            try out.append(gpa, '"');
        },
        c.DPI_NATIVE_TYPE_INTERVAL_DS => {
            const iv = v.asIntervalDS;
            const neg = iv.days < 0 or iv.hours < 0 or iv.minutes < 0 or iv.seconds < 0 or iv.fseconds < 0;
            try out.appendSlice(gpa, if (neg) "\"-P" else "\"P");
            try out.print(gpa, "{d}DT{d}H{d}M{d}", .{ @abs(iv.days), @abs(iv.hours), @abs(iv.minutes), @abs(iv.seconds) });
            if (iv.fseconds != 0) {
                var frac: [9]u8 = undefined;
                _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{@min(@abs(iv.fseconds), 999_999_999)}) catch unreachable;
                try out.append(gpa, '.');
                try out.appendSlice(gpa, std.mem.trimEnd(u8, &frac, "0"));
            }
            try out.appendSlice(gpa, "S\"");
        },
        c.DPI_NATIVE_TYPE_INTERVAL_YM => {
            const iv = v.asIntervalYM;
            const neg = iv.years < 0 or iv.months < 0;
            try out.print(gpa, "\"{s}P{d}Y{d}M\"", .{ if (neg) "-" else "", @abs(iv.years), @abs(iv.months) });
        },
        else => return error.UnsupportedJsonNode,
    }
}

fn writeJsonFloat(gpa: std.mem.Allocator, out: *std.ArrayList(u8), x: f64) JsonError!void {
    if (std.math.isNan(x)) return out.appendSlice(gpa, "\"NaN\"");
    if (std.math.isInf(x)) return out.appendSlice(gpa, if (x > 0) "\"Infinity\"" else "\"-Infinity\"");
    const ax = @abs(x);
    if (ax != 0 and (ax >= 1e21 or ax < 1e-6)) return out.print(gpa, "{e}", .{x});
    return out.print(gpa, "{d}", .{x});
}

fn writeJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), str: []const u8) JsonError!void {
    try out.append(gpa, '"');
    for (str) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0C => try out.appendSlice(gpa, "\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try out.print(gpa, "\\u{X:0>4}", .{ch}),
            else => try out.append(gpa, ch), // UTF-8 passes through unchanged
        }
    }
    try out.append(gpa, '"');
}

// ---------------------------------------------------------------------------
// VECTOR (Oracle 23ai+) -> LIST
// ---------------------------------------------------------------------------

pub const VectorError = error{ VectorFormatMismatch, VectorTooLarge, InvalidSparseIndex };

/// Densified sparse vectors larger than this are rejected (DuckDB lists are dense).
pub const max_vector_elements: usize = 1 << 24;

/// Number of LIST elements one VECTOR value produces for element type `elem`.
pub fn vectorLen(info: *const c.dpiVectorInfo, elem: ListElem) VectorError!usize {
    const n: usize = info.numDimensions;
    if (info.format == c.DPI_VECTOR_FORMAT_BINARY) {
        if (elem != .utinyint) return error.VectorFormatMismatch;
        return n / 8; // dimensions are bits, packed 8 per byte
    }
    if (elem == .utinyint) return error.VectorFormatMismatch;
    if (n > max_vector_elements) return error.VectorTooLarge;
    return n;
}

fn dimAt(info: *const c.dpiVectorInfo, i: usize) f64 {
    return switch (info.format) {
        c.DPI_VECTOR_FORMAT_FLOAT32 => info.dimensions.asFloat[i],
        c.DPI_VECTOR_FORMAT_FLOAT64 => info.dimensions.asDouble[i],
        c.DPI_VECTOR_FORMAT_INT8 => @floatFromInt(info.dimensions.asInt8[i]),
        else => 0,
    };
}

/// Write the elements of one VECTOR value into `out` (length vectorLen()).
/// Sparse vectors are densified (zeros for absent dimensions).
pub fn convertVector(info: *const c.dpiVectorInfo, elem: ListElem, out: [*]u8) VectorError!void {
    const len = try vectorLen(info, elem);
    switch (elem) {
        .utinyint => {
            const dst: [*]u8 = out;
            const src: [*]const u8 = @ptrCast(info.dimensions.asPtr orelse return);
            @memcpy(dst[0..len], src[0..len]);
        },
        inline .float, .double => |e| {
            const T = if (e == .float) f32 else f64;
            const dst: [*]T = @ptrCast(@alignCast(out));
            if (info.isSparse != 0) {
                @memset(dst[0..len], 0);
                var k: usize = 0;
                while (k < info.numSparseValues) : (k += 1) {
                    const idx: usize = info.sparseIndices[k];
                    if (idx >= len) return error.InvalidSparseIndex;
                    dst[idx] = @floatCast(dimAt(info, k));
                }
            } else {
                var i: usize = 0;
                while (i < len) : (i += 1) dst[i] = @floatCast(dimAt(info, i));
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Tests (hand-built dpiDataTypeInfo / dpiData values; no OCI needed)
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

fn planOf(ot: c.dpiOracleTypeNum, p: i16, s: i8) !ColumnPlan {
    const ti = typeInfo(ot, p, s);
    return planColumn(&ti);
}

test "NUMBER mapping" {
    const N = c.DPI_ORACLE_TYPE_NUMBER;
    // NUMBER(p,0), p <= 18 -> BIGINT
    try testing.expectEqual(DuckKind.bigint, (try planOf(N, 10, 0)).kind);
    try testing.expectEqual(DuckKind.bigint, (try planOf(N, 18, 0)).kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_INT64), (try planOf(N, 1, 0)).native_type);
    // NUMBER(19..38,0) -> DECIMAL(p,0)
    const p19 = try planOf(N, 19, 0);
    try testing.expectEqual(DuckKind.decimal, p19.kind);
    try testing.expectEqual(@as(u8, 19), p19.width);
    // NUMBER(p,s) -> DECIMAL(p,s)
    const p102 = try planOf(N, 10, 2);
    try testing.expectEqual(DuckKind.decimal, p102.kind);
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
    try testing.expectEqual(DuckKind.bigint, (try planOf(N, 5, -2)).kind);
    try testing.expectEqual(DuckKind.decimal, (try planOf(N, 30, -5)).kind);
    try testing.expectEqual(DuckKind.number_double, (try planOf(N, 38, -5)).kind);
    // unconstrained NUMBER and FLOAT(b) -> DOUBLE (checked: see "unconstrained NUMBER follows the number mode")
    try testing.expectEqual(DuckKind.number_double, (try planOf(N, 0, -127)).kind);
    try testing.expectEqual(DuckKind.number_double, (try planOf(N, 126, -127)).kind);
}

test "other type mappings" {
    try testing.expectEqual(DuckKind.double, (try planOf(c.DPI_ORACLE_TYPE_NATIVE_DOUBLE, 0, 0)).kind);
    try testing.expectEqual(DuckKind.float, (try planOf(c.DPI_ORACLE_TYPE_NATIVE_FLOAT, 0, 0)).kind);
    for ([_]c.dpiOracleTypeNum{ c.DPI_ORACLE_TYPE_VARCHAR, c.DPI_ORACLE_TYPE_NVARCHAR, c.DPI_ORACLE_TYPE_CHAR, c.DPI_ORACLE_TYPE_NCHAR }) |ot| {
        const p = try planOf(ot, 0, 0);
        try testing.expectEqual(DuckKind.varchar, p.kind);
        try testing.expectEqual(@as(u32, 40), p.size);
    }
    const clob = try planOf(c.DPI_ORACLE_TYPE_CLOB, 0, 0);
    try testing.expectEqual(DuckKind.varchar, clob.kind);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, c.DPI_ORACLE_TYPE_LONG_VARCHAR), clob.oracle_type);
    const nclob = try planOf(c.DPI_ORACLE_TYPE_NCLOB, 0, 0);
    try testing.expectEqual(DuckKind.varchar, nclob.kind);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, c.DPI_ORACLE_TYPE_LONG_NVARCHAR), nclob.oracle_type);
    try testing.expectEqual(DuckKind.blob, (try planOf(c.DPI_ORACLE_TYPE_RAW, 0, 0)).kind);
    const blob = try planOf(c.DPI_ORACLE_TYPE_BLOB, 0, 0);
    try testing.expectEqual(DuckKind.blob, blob.kind);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, c.DPI_ORACLE_TYPE_LONG_RAW), blob.oracle_type);
    try testing.expectEqual(DuckKind.timestamp, (try planOf(c.DPI_ORACLE_TYPE_DATE, 0, 0)).kind);
    try testing.expectEqual(DuckKind.timestamp, (try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP, 0, 0)).kind);
    try testing.expectEqual(DuckKind.timestamptz, (try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP_TZ, 0, 0)).kind);
    try testing.expectEqual(DuckKind.timestamptz, (try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP_LTZ, 0, 0)).kind);
    try testing.expectEqual(DuckKind.interval, (try planOf(c.DPI_ORACLE_TYPE_INTERVAL_DS, 0, 0)).kind);
    try testing.expect((try planOf(c.DPI_ORACLE_TYPE_ROWID, 0, 0)).is_rowid);
    try testing.expectError(error.UnsupportedType, planOf(c.DPI_ORACLE_TYPE_OBJECT, 0, 0));
    try testing.expectError(error.UnsupportedType, planOf(c.DPI_ORACLE_TYPE_BFILE, 0, 0));
}

test "fetch batch sizing" {
    const narrow = [_]ColumnPlan{ try planOf(c.DPI_ORACLE_TYPE_NUMBER, 10, 0), try planOf(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0) };
    try testing.expectEqual(@as(u32, 2048), fetchRows(&narrow, 2048, 64 << 20));
    var wide_ti = typeInfo(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0);
    wide_ti.clientSizeInBytes = 16000;
    const w = try planColumn(&wide_ti);
    const wide = [_]ColumnPlan{ w, w, w, w, w, w, w, w, w, w };
    const n = fetchRows(&wide, 2048, 64 << 20);
    try testing.expect(n < 2048 and n > 300);
    try testing.expectEqual(@as(u32, 1), fetchRows(&wide, 2048, 10));
}

test "daysFromCivil" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try testing.expectEqual(@as(i64, 10957), daysFromCivil(2000, 1, 1));
    try testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29));
    try testing.expectEqual(@as(i64, -719162), daysFromCivil(1, 1, 1));
    try testing.expectEqual(@as(i64, 2932896), daysFromCivil(9999, 12, 31));
}

fn mkTs(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8, ns: u32, tzh: i8, tzm: i8) c.dpiTimestamp {
    return .{ .year = y, .month = mo, .day = d, .hour = h, .minute = mi, .second = s, .fsecond = ns, .tzHourOffset = tzh, .tzMinuteOffset = tzm };
}

test "timestamp conversion via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    d.value.asTimestamp = mkTs(2024, 2, 29, 13, 45, 30, 123456789, 0, 0);
    const plan = try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP, 0, 0);
    var out: [2]i64 = .{ 0, 0 };
    try storeFixed(&plan, &d.value, @ptrCast(&out), 1);
    // SELECT epoch_us(TIMESTAMP '2024-02-29 13:45:30.123456') = 1709214330123456
    try testing.expectEqual(@as(i64, 1709214330123456), out[1]);

    // DATE before the epoch
    d.value.asTimestamp = mkTs(1900, 1, 1, 0, 0, 0, 0, 0, 0);
    try storeFixed(&plan, &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i64, -2208988800000000), out[0]);
}

test "timestamptz conversion applies offset" {
    var d = std.mem.zeroes(c.dpiData);
    // 2024-01-01 10:00:00 +05:30  == 2024-01-01 04:30:00 UTC
    d.value.asTimestamp = mkTs(2024, 1, 1, 10, 0, 0, 0, 5, 30);
    const plan = try planOf(c.DPI_ORACLE_TYPE_TIMESTAMP_TZ, 0, 0);
    var out: [1]i64 = .{0};
    try storeFixed(&plan, &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i64, 1704083400000000), out[0]);
    // -03:30 offset (both components negative in ODPI-C)
    d.value.asTimestamp = mkTs(2024, 1, 1, 0, 0, 0, 0, -3, -30);
    try storeFixed(&plan, &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i64, 1704079800000000), out[0]);
}

test "parseDecimal" {
    try testing.expectEqual(@as(i128, 12345), try parseDecimal("123.45", 10, 2));
    try testing.expectEqual(@as(i128, -12345), try parseDecimal("-123.45", 10, 2));
    try testing.expectEqual(@as(i128, 12300), try parseDecimal("123", 10, 2));
    try testing.expectEqual(@as(i128, 50), try parseDecimal("0.5", 10, 2));
    try testing.expectEqual(@as(i128, 1), try parseDecimal("0.001", 5, 3));
    try testing.expectEqual(@as(i128, 0), try parseDecimal("0", 5, 3));
    try testing.expectEqual(@as(i128, 13), try parseDecimal("0.125", 5, 2)); // rounds half up
    try testing.expectEqual(@as(i128, -13), try parseDecimal("-0.125", 5, 2));
    try testing.expectEqual(@as(i128, 99999999999999999999999999999999999999), try parseDecimal("99999999999999999999999999999999999999", 38, 0));
    try testing.expectEqual(@as(i128, -99999999999999999999999999999999999999), try parseDecimal("-9999999999999999999999999999.9999999999", 38, 10));
    try testing.expectError(error.DecimalOverflow, parseDecimal("1000", 3, 0));
    try testing.expectError(error.DecimalOverflow, parseDecimal("100.0", 4, 2));
    try testing.expectError(error.DecimalOverflow, parseDecimal("99999999999999999999999999999999999999", 38, 2));
    try testing.expectError(error.InvalidNumber, parseDecimal("", 4, 2));
    try testing.expectError(error.InvalidNumber, parseDecimal("1e5", 4, 2));
    try testing.expectError(error.InvalidNumber, parseDecimal("1.2.3", 4, 2));
}

test "decimal storage widths via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    var text = "-1234.56".*;
    d.value.asBytes = .{ .ptr = &text, .length = text.len, .encoding = null };

    var p = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 6, 2); // int32 storage
    var o32: [1]i32 = .{0};
    try storeFixed(&p, &d.value, @ptrCast(&o32), 0);
    try testing.expectEqual(@as(i32, -123456), o32[0]);

    p = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 30, 2); // hugeint storage
    var oh: [1]c.duckdb_hugeint = undefined;
    try storeFixed(&p, &d.value, @ptrCast(&oh), 0);
    try testing.expectEqual(@as(i64, -1), oh[0].upper);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -123456))), oh[0].lower);

    var small = "12.3".*;
    d.value.asBytes = .{ .ptr = &small, .length = small.len, .encoding = null };
    p = try planOf(c.DPI_ORACLE_TYPE_NUMBER, 4, 1); // int16 storage
    var o16: [1]i16 = .{0};
    try storeFixed(&p, &d.value, @ptrCast(&o16), 0);
    try testing.expectEqual(@as(i16, 123), o16[0]);
}

test "numeric and boolean natives via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    var o64: [1]i64 = .{0};
    d.value.asInt64 = -42;
    try storeFixed(&(try planOf(c.DPI_ORACLE_TYPE_NUMBER, 9, 0)), &d.value, @ptrCast(&o64), 0);
    try testing.expectEqual(@as(i64, -42), o64[0]);

    var of64: [1]f64 = .{0};
    d.value.asDouble = 3.25;
    // the lossy_double fast path takes OCI's own double conversion
    try storeFixed(&(try planWith(c.DPI_ORACLE_TYPE_NUMBER, 0, -127, .lossy_double)), &d.value, @ptrCast(&of64), 0);
    try testing.expectEqual(@as(f64, 3.25), of64[0]);

    var of32: [1]f32 = .{0};
    d.value.asFloat = 1.5;
    try storeFixed(&(try planOf(c.DPI_ORACLE_TYPE_NATIVE_FLOAT, 0, 0)), &d.value, @ptrCast(&of32), 0);
    try testing.expectEqual(@as(f32, 1.5), of32[0]);

    var ob: [1]bool = .{false};
    d.value.asBoolean = 1;
    try storeFixed(&(try planOf(c.DPI_ORACLE_TYPE_BOOLEAN, 0, 0)), &d.value, @ptrCast(&ob), 0);
    try testing.expect(ob[0]);

    // strings are not fixed-width
    try testing.expectError(error.NotFixed, storeFixed(&(try planOf(c.DPI_ORACLE_TYPE_VARCHAR, 0, 0)), &d.value, @ptrCast(&ob), 0));
}

test "interval conversion via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    d.value.asIntervalDS = .{ .days = 3, .hours = 4, .minutes = 5, .seconds = 6, .fseconds = 7_000_000 };
    var out: [1]c.duckdb_interval = undefined;
    try storeFixed(&(try planOf(c.DPI_ORACLE_TYPE_INTERVAL_DS, 0, 0)), &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i32, 3), out[0].days);
    try testing.expectEqual(@as(i64, (4 * 3600 + 5 * 60 + 6) * 1_000_000 + 7_000), out[0].micros);

    d.value.asIntervalYM = .{ .years = 2, .months = 3 };
    try storeFixed(&(try planOf(c.DPI_ORACLE_TYPE_INTERVAL_YM, 0, 0)), &d.value, @ptrCast(&out), 0);
    try testing.expectEqual(@as(i32, 27), out[0].months);
}

// --- Oracle 23ai+ types ------------------------------------------------------

test "23ai type plans: BOOLEAN, JSON, OSON BLOB, VECTOR" {
    const b = try planOf(c.DPI_ORACLE_TYPE_BOOLEAN, 0, 0);
    try testing.expectEqual(DuckKind.boolean, b.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_BOOLEAN), b.native_type);

    const j = try planOf(c.DPI_ORACLE_TYPE_JSON, 0, 0);
    try testing.expectEqual(DuckKind.varchar, j.kind);
    try testing.expect(j.is_json);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_JSON), j.native_type);

    // BLOB IS JSON (FORMAT OSON) -> JSON text; a plain BLOB stays BLOB (19c behaviour)
    var oson = typeInfo(c.DPI_ORACLE_TYPE_BLOB, 0, 0);
    oson.isOson = 1;
    try testing.expect((try planColumn(&oson)).is_json);
    const plain = try planOf(c.DPI_ORACLE_TYPE_BLOB, 0, 0);
    try testing.expect(!plain.is_json);
    try testing.expectEqual(DuckKind.blob, plain.kind);

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
        const p = try planColumn(&ti);
        try testing.expectEqual(DuckKind.list, p.kind);
        try testing.expectEqual(cs.elem, p.list_elem);
        try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_VECTOR), p.native_type);
    }
}

test "BOOLEAN value via dpiData" {
    var d = std.mem.zeroes(c.dpiData);
    var out: [2]bool = .{ true, true };
    d.value.asBoolean = 0;
    try storeFixed(&(try planOf(c.DPI_ORACLE_TYPE_BOOLEAN, 0, 0)), &d.value, @ptrCast(&out), 1);
    try testing.expect(!out[1]);
}

fn jsonText(node: *const c.dpiJsonNode) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try serializeJson(testing.allocator, &out, node);
    return out.toOwnedSlice(testing.allocator);
}

fn bytesBuf(str: []const u8) c.dpiDataBuffer {
    var v = std.mem.zeroes(c.dpiDataBuffer);
    v.asBytes = .{ .ptr = @constCast(str.ptr), .length = @intCast(str.len), .encoding = null };
    return v;
}

test "JSON serialisation of a hand-built dpiJsonNode tree" {
    // {"id":123.45,"name":"a\"b","ok":true,"tags":[null,1.5,"x"],"raw":RAW(CAFE),"ts":..., "big":1e300}
    var v_num = bytesBuf("123.45");
    var v_str = bytesBuf("a\"b\n\xc3\xbc");
    var v_true = std.mem.zeroes(c.dpiDataBuffer);
    v_true.asBoolean = 1;
    var v_dbl = std.mem.zeroes(c.dpiDataBuffer);
    v_dbl.asDouble = 1.5;
    var v_x = bytesBuf("x");
    var v_raw = bytesBuf("\xca\xfe");
    var v_ts = std.mem.zeroes(c.dpiDataBuffer);
    v_ts.asTimestamp = mkTs(2024, 2, 29, 13, 45, 30, 123456000, 0, 0);
    var v_big = std.mem.zeroes(c.dpiDataBuffer);
    v_big.asDouble = 1e300;
    var v_ds = std.mem.zeroes(c.dpiDataBuffer);
    v_ds.asIntervalDS = .{ .days = 3, .hours = 4, .minutes = 5, .seconds = 6, .fseconds = 7_000_000 };

    var elems = [_]c.dpiJsonNode{
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NONE, .nativeTypeNum = c.DPI_NATIVE_TYPE_NULL, .value = null },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NUMBER, .nativeTypeNum = c.DPI_NATIVE_TYPE_DOUBLE, .value = &v_dbl },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_VARCHAR, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &v_x },
    };
    var v_arr = std.mem.zeroes(c.dpiDataBuffer);
    v_arr.asJsonArray = .{ .numElements = elems.len, .elements = &elems, .elementValues = null };

    var names = [_][*c]u8{ @constCast("id"), @constCast("name"), @constCast("ok"), @constCast("tags"), @constCast("raw"), @constCast("ts"), @constCast("big"), @constCast("ds") };
    var lens = [_]u32{ 2, 4, 2, 4, 3, 2, 3, 2 };
    var fields = [_]c.dpiJsonNode{
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NUMBER, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &v_num },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_VARCHAR, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &v_str },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_BOOLEAN, .nativeTypeNum = c.DPI_NATIVE_TYPE_BOOLEAN, .value = &v_true },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_JSON_ARRAY, .nativeTypeNum = c.DPI_NATIVE_TYPE_JSON_ARRAY, .value = &v_arr },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_RAW, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &v_raw },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_TIMESTAMP, .nativeTypeNum = c.DPI_NATIVE_TYPE_TIMESTAMP, .value = &v_ts },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NATIVE_DOUBLE, .nativeTypeNum = c.DPI_NATIVE_TYPE_DOUBLE, .value = &v_big },
        .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_INTERVAL_DS, .nativeTypeNum = c.DPI_NATIVE_TYPE_INTERVAL_DS, .value = &v_ds },
    };
    var v_obj = std.mem.zeroes(c.dpiDataBuffer);
    v_obj.asJsonObject = .{ .numFields = fields.len, .fieldNames = &names, .fieldNameLengths = &lens, .fields = &fields, .fieldValues = null };
    const top: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_JSON_OBJECT, .nativeTypeNum = c.DPI_NATIVE_TYPE_JSON_OBJECT, .value = &v_obj };

    const txt = try jsonText(&top);
    defer testing.allocator.free(txt);
    try testing.expectEqualStrings(
        "{\"id\":123.45,\"name\":\"a\\\"b\\n\xc3\xbc\",\"ok\":true,\"tags\":[null,1.5,\"x\"],\"raw\":\"CAFE\"," ++
            "\"ts\":\"2024-02-29T13:45:30.123456\",\"big\":1e300,\"ds\":\"P3DT4H5M6.007S\"}",
        txt,
    );
    // the output is valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, txt, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 8), parsed.value.object.count());
}

test "JSON scalars, empty containers, control chars, non-finite" {
    var v_nan = std.mem.zeroes(c.dpiDataBuffer);
    v_nan.asDouble = std.math.nan(f64);
    const nan_node: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_NATIVE_DOUBLE, .nativeTypeNum = c.DPI_NATIVE_TYPE_DOUBLE, .value = &v_nan };
    const t1 = try jsonText(&nan_node);
    defer testing.allocator.free(t1);
    try testing.expectEqualStrings("\"NaN\"", t1);

    var v_empty = std.mem.zeroes(c.dpiDataBuffer);
    v_empty.asJsonArray = .{ .numElements = 0, .elements = null, .elementValues = null };
    const arr: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_JSON_ARRAY, .nativeTypeNum = c.DPI_NATIVE_TYPE_JSON_ARRAY, .value = &v_empty };
    const t2 = try jsonText(&arr);
    defer testing.allocator.free(t2);
    try testing.expectEqualStrings("[]", t2);

    var v_ctl = bytesBuf("\x01\t");
    const ctl: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_VARCHAR, .nativeTypeNum = c.DPI_NATIVE_TYPE_BYTES, .value = &v_ctl };
    const t3 = try jsonText(&ctl);
    defer testing.allocator.free(t3);
    try testing.expectEqualStrings("\"\\u0001\\t\"", t3);

    var v_date = std.mem.zeroes(c.dpiDataBuffer);
    v_date.asTimestamp = mkTs(1999, 12, 31, 23, 59, 59, 0, 0, 0);
    const date: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_DATE, .nativeTypeNum = c.DPI_NATIVE_TYPE_TIMESTAMP, .value = &v_date };
    const t4 = try jsonText(&date);
    defer testing.allocator.free(t4);
    try testing.expectEqualStrings("\"1999-12-31T23:59:59\"", t4);

    var v_ym = std.mem.zeroes(c.dpiDataBuffer);
    v_ym.asIntervalYM = .{ .years = -2, .months = -3 };
    const ym: c.dpiJsonNode = .{ .oracleTypeNum = c.DPI_ORACLE_TYPE_INTERVAL_YM, .nativeTypeNum = c.DPI_NATIVE_TYPE_INTERVAL_YM, .value = &v_ym };
    const t5 = try jsonText(&ym);
    defer testing.allocator.free(t5);
    try testing.expectEqualStrings("\"-P2Y3M\"", t5);
}

fn vecInfo(format: u8, dims: u32, size: u8, ptr: ?*anyopaque) c.dpiVectorInfo {
    var vi = std.mem.zeroes(c.dpiVectorInfo);
    vi.format = format;
    vi.numDimensions = dims;
    vi.dimensionSize = size;
    vi.dimensions.asPtr = ptr;
    return vi;
}

test "VECTOR conversion from hand-built dpiVectorInfo" {
    // FLOAT32 -> FLOAT[]
    var f32s = [_]f32{ 1.5, -2.0, 3.25 };
    var vi = vecInfo(c.DPI_VECTOR_FORMAT_FLOAT32, 3, 4, &f32s);
    try testing.expectEqual(@as(usize, 3), try vectorLen(&vi, .float));
    var of: [3]f32 = undefined;
    try convertVector(&vi, .float, @ptrCast(&of));
    try testing.expectEqualSlices(f32, &f32s, &of);

    // FLOAT64 -> DOUBLE[]
    var f64s = [_]f64{ 0.1, 1e300 };
    vi = vecInfo(c.DPI_VECTOR_FORMAT_FLOAT64, 2, 8, &f64s);
    var od: [2]f64 = undefined;
    try convertVector(&vi, .double, @ptrCast(&od));
    try testing.expectEqualSlices(f64, &f64s, &od);

    // INT8 -> FLOAT[] (exact)
    var i8s = [_]i8{ -128, 0, 127 };
    vi = vecInfo(c.DPI_VECTOR_FORMAT_INT8, 3, 1, &i8s);
    try convertVector(&vi, .float, @ptrCast(&of));
    try testing.expectEqualSlices(f32, &[_]f32{ -128, 0, 127 }, &of);

    // flexible-format column (DOUBLE[]) receiving a FLOAT32 value
    vi = vecInfo(c.DPI_VECTOR_FORMAT_FLOAT32, 3, 4, &f32s);
    var od3: [3]f64 = undefined;
    try convertVector(&vi, .double, @ptrCast(&od3));
    try testing.expectEqualSlices(f64, &[_]f64{ 1.5, -2.0, 3.25 }, &od3);

    // BINARY: 16 bit dimensions packed into 2 bytes -> UTINYINT[2]
    var bits = [_]u8{ 0xA5, 0x0F };
    vi = vecInfo(c.DPI_VECTOR_FORMAT_BINARY, 16, 1, &bits);
    try testing.expectEqual(@as(usize, 2), try vectorLen(&vi, .utinyint));
    var ob: [2]u8 = undefined;
    try convertVector(&vi, .utinyint, @ptrCast(&ob));
    try testing.expectEqualSlices(u8, &bits, &ob);
    try testing.expectError(error.VectorFormatMismatch, vectorLen(&vi, .float));

    // sparse FLOAT64 vector of 6 dims with values at 1 and 4 -> densified
    var sv = [_]f64{ 7.0, -1.0 };
    var sidx = [_]u32{ 1, 4 };
    vi = vecInfo(c.DPI_VECTOR_FORMAT_FLOAT64, 6, 8, &sv);
    vi.isSparse = 1;
    vi.numSparseValues = 2;
    vi.sparseIndices = &sidx;
    var o6: [6]f64 = undefined;
    try convertVector(&vi, .double, @ptrCast(&o6));
    try testing.expectEqualSlices(f64, &[_]f64{ 0, 7, 0, 0, -1, 0 }, &o6);
    sidx[1] = 6; // out of range
    try testing.expectError(error.InvalidSparseIndex, convertVector(&vi, .double, @ptrCast(&o6)));

    // empty vector
    vi = vecInfo(c.DPI_VECTOR_FORMAT_FLOAT32, 0, 4, null);
    try testing.expectEqual(@as(usize, 0), try vectorLen(&vi, .float));
}

// --- NUMBER that has no exact DECIMAL form (review F1) ------------------------
// Expected values: Python `int(float(n)) == n` for each literal.

test "parseNumberAsDouble: integers a double holds exactly" {
    try testing.expectEqual(@as(f64, 9007199254740992.0), try parseNumberAsDouble("9007199254740992")); // 2^53
    try testing.expectEqual(@as(f64, 9007199254740994.0), try parseNumberAsDouble("9007199254740994")); // even above 2^53
    try testing.expectEqual(@as(f64, 1e22), try parseNumberAsDouble("10000000000000000000000"));
    try testing.expectEqual(@as(f64, 1152921504606846976.0), try parseNumberAsDouble("1152921504606846976")); // 2^60
    try testing.expectEqual(@as(f64, -42.0), try parseNumberAsDouble("-42"));
    try testing.expectEqual(@as(f64, 0.0), try parseNumberAsDouble("0"));
}

test "parseNumberAsDouble: integers a double cannot hold are an error, not rounded" {
    try testing.expectError(error.PrecisionLoss, parseNumberAsDouble("9007199254740993")); // 2^53 + 1
    try testing.expectError(error.PrecisionLoss, parseNumberAsDouble("-9007199254740993"));
    try testing.expectError(error.PrecisionLoss, parseNumberAsDouble("12345678901234567890"));
    try testing.expectError(error.PrecisionLoss, parseNumberAsDouble("123456789012345678"));
    try testing.expectError(error.PrecisionLoss, parseNumberAsDouble("1152921504606846977")); // 2^60 + 1
    try testing.expectError(error.PrecisionLoss, parseNumberAsDouble("99999999999999999999999999999999999999")); // 38 nines
}

test "parseNumberAsDouble: fractions and huge magnitudes are accepted" {
    try testing.expectEqual(@as(f64, 123.456), try parseNumberAsDouble("123.456"));
    try testing.expectEqual(@as(f64, -0.5), try parseNumberAsDouble("-.5"));
    try testing.expectEqual(@as(f64, 0.5), try parseNumberAsDouble(".5"));
    // 1/3 as Oracle prints it (40 digits): approximate by nature, must not be rejected
    try testing.expectEqual(@as(f64, 0.3333333333333333), try parseNumberAsDouble("0.3333333333333333333333333333333333333333"));
    // 1 followed by 100 zeros: more than 38 digits is a floating-point magnitude
    const big = "1" ++ "0" ** 100;
    try testing.expectEqual(@as(f64, 1e100), try parseNumberAsDouble(big));
    // an integral value written with a fractional zero part is still integral
    try testing.expectError(error.PrecisionLoss, parseNumberAsDouble("9007199254740993.0"));
}

test "parseNumberAsDouble: malformed text" {
    try testing.expectError(error.InvalidNumber, parseNumberAsDouble(""));
    try testing.expectError(error.InvalidNumber, parseNumberAsDouble("-"));
    try testing.expectError(error.InvalidNumber, parseNumberAsDouble("1e5"));
    try testing.expectError(error.InvalidNumber, parseNumberAsDouble("1.2.3"));
    try testing.expectError(error.InvalidNumber, parseNumberAsDouble("12a"));
}

test "NumberMode.parse" {
    try testing.expectEqual(NumberMode.double, NumberMode.parse("double").?);
    try testing.expectEqual(NumberMode.lossy_double, NumberMode.parse("LOSSY_DOUBLE").?);
    try testing.expectEqual(NumberMode.varchar, NumberMode.parse("Varchar").?);
    try testing.expect(NumberMode.parse("decimal") == null);
}

fn planWith(ot: c.dpiOracleTypeNum, p: i16, s: i8, mode: NumberMode) !ColumnPlan {
    const ti = typeInfo(ot, p, s);
    return planColumnOpts(&ti, .{ .number = mode });
}

test "unconstrained NUMBER follows the number mode; exact types never do" {
    const N = c.DPI_ORACLE_TYPE_NUMBER;
    // default: checked double, fetched as text
    const d = try planWith(N, 0, -127, .double);
    try testing.expectEqual(DuckKind.number_double, d.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_BYTES), d.native_type);
    try testing.expectEqual(@as(c.duckdb_type, c.DUCKDB_TYPE_DOUBLE), d.kind.duckdbType());
    // lossy: the old fast path
    const l = try planWith(N, 0, -127, .lossy_double);
    try testing.expectEqual(DuckKind.double, l.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_DOUBLE), l.native_type);
    // varchar: exact text
    const v = try planWith(N, 0, -127, .varchar);
    try testing.expectEqual(DuckKind.varchar, v.kind);
    try testing.expectEqual(@as(c.dpiNativeTypeNum, c.DPI_NATIVE_TYPE_BYTES), v.native_type);
    try testing.expectEqual(@as(c.dpiOracleTypeNum, N), v.oracle_type);
    // FLOAT(b) and NUMBER wider than DECIMAL(38) take the same path
    try testing.expectEqual(DuckKind.number_double, (try planWith(N, 126, -127, .double)).kind);
    try testing.expectEqual(DuckKind.number_double, (try planWith(N, 38, -5, .double)).kind);
    try testing.expectEqual(DuckKind.varchar, (try planWith(N, 50, 10, .varchar)).kind);
    // exact types are unaffected by the mode
    try testing.expectEqual(DuckKind.bigint, (try planWith(N, 10, 0, .varchar)).kind);
    try testing.expectEqual(DuckKind.decimal, (try planWith(N, 10, 2, .varchar)).kind);
    try testing.expectEqual(DuckKind.double, (try planWith(c.DPI_ORACLE_TYPE_NATIVE_DOUBLE, 0, 0, .varchar)).kind);
}

test "number_double column stores doubles and rejects lossy integers" {
    var plan = try planWith(c.DPI_ORACLE_TYPE_NUMBER, 0, -127, .double);
    var d = std.mem.zeroes(c.dpiData);
    var text = "123.5".*;
    d.value.asBytes = .{ .ptr = &text, .length = text.len, .encoding = null };
    var out: [2]f64 = .{ 0, 0 };
    try storeFixed(&plan, &d.value, @ptrCast(&out), 1);
    try testing.expectEqual(@as(f64, 123.5), out[1]);

    var big = "9007199254740993".*;
    d.value.asBytes = .{ .ptr = &big, .length = big.len, .encoding = null };
    try testing.expectError(error.PrecisionLoss, storeFixed(&plan, &d.value, @ptrCast(&out), 0));
    try testing.expectEqual(@as(f64, 0), out[0]); // nothing was written
}

test "varchar-mode number needs the full NUMBER text buffer in the batch budget" {
    const plan = try planWith(c.DPI_ORACLE_TYPE_NUMBER, 0, -127, .varchar);
    try testing.expect(rowBufferBytes(&plan) >= 172);
}
