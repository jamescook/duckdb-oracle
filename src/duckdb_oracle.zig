//! duckdb-oracle: query Oracle from DuckDB through the stable C Extension API + ODPI-C.
//!
//! SQL surface (v1):
//!   oracle_query(dsn VARCHAR, sql VARCHAR, user := VARCHAR, password_env := VARCHAR)
//!   oracle_client_info()
const std = @import("std");
const compat = @import("compat.zig");
const c = @import("c.zig").c;
const column = @import("column.zig");
const oracle = @import("oracle.zig");
const arch = @import("arch.zig");
const timeouts = @import("timeouts.zig");
const cursor_mod = @import("cursor.zig");
const session_mod = @import("session.zig");
const OdpiBackend = @import("odpi_backend.zig").OdpiBackend;
const OdpiReader = @import("odpi_backend.zig").OdpiReader;

const OdpiCursor = cursor_mod.Cursor(OdpiBackend);
const build_options = @import("build_options");

const alloc = std.heap.c_allocator;
const Msg = oracle.Msg;

/// The DuckDB C API function pointer struct (what DUCKDB_EXTENSION_GLOBAL
/// defines in C extensions). Filled once in the entrypoint.
var duckdb_ext_api: c.duckdb_ext_api_v1 = std.mem.zeroes(c.duckdb_ext_api_v1);

inline fn api() *c.duckdb_ext_api_v1 {
    return &duckdb_ext_api;
}

/// Call a DuckDB C API function through the function pointer struct.
inline fn duck(comptime name: []const u8) @typeInfo(@TypeOf(@field(duckdb_ext_api, name))).optional.child {
    return @field(api(), name).?;
}

/// C API version requested from DuckDB; must equal the one in the footer.
const capi_version_z: [:0]const u8 = std.fmt.comptimePrint("{s}", .{build_options.capi_version});

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

/// C Extension API entrypoint, resolved by DuckDB by name for ABI type
/// C_STRUCT. Equivalent to the DUCKDB_EXTENSION_ENTRYPOINT macro in
/// duckdb_extension.h: request the API struct for our target C API version,
/// open a connection, register the functions, disconnect.
///
/// Deliberately nothing Oracle-related happens here: the ODPI-C context (and
/// with it the OCI library) is created lazily on first use, so LOAD succeeds
/// on machines without Oracle Instant Client.
export fn duckdb_oracle_init_c_api(info: c.duckdb_extension_info, access: [*c]c.struct_duckdb_extension_access) callconv(.c) bool {
    const acc = access orelse return false;
    const get_api = acc.*.get_api orelse return false;
    const set_error = acc.*.set_error orelse return false;
    const get_database = acc.*.get_database orelse return false;

    const res: *const c.duckdb_ext_api_v1 = @ptrCast(@alignCast(get_api(info, capi_version_z.ptr) orelse return false));
    duckdb_ext_api = res.*;

    const db = get_database(info) orelse {
        set_error(info, "duckdb_oracle: failed to get database");
        return false;
    };
    var conn: c.duckdb_connection = null;
    if (duck("duckdb_connect")(db.*, &conn) == c.DuckDBError) {
        set_error(info, "Failed to open connection to database");
        return false;
    }
    defer duck("duckdb_disconnect")(&conn);

    if (!registerOracleQuery(conn)) {
        set_error(info, "duckdb_oracle: failed to register oracle_query");
        return false;
    }
    if (!registerClientInfo(conn)) {
        set_error(info, "duckdb_oracle: failed to register oracle_client_info");
        return false;
    }
    return true;
}

fn logicalType(t: c.duckdb_type) c.duckdb_logical_type {
    return duck("duckdb_create_logical_type")(t);
}

fn registerOracleQuery(conn: c.duckdb_connection) bool {
    var tf = duck("duckdb_create_table_function")();
    defer duck("duckdb_destroy_table_function")(&tf);
    duck("duckdb_table_function_set_name")(tf, "oracle_query");

    var vt = logicalType(c.DUCKDB_TYPE_VARCHAR);
    defer duck("duckdb_destroy_logical_type")(&vt);
    duck("duckdb_table_function_add_parameter")(tf, vt); // dsn
    duck("duckdb_table_function_add_parameter")(tf, vt); // sql
    duck("duckdb_table_function_add_named_parameter")(tf, "user", vt);
    // No `password` parameter on purpose: DuckDB echoes the failing SQL text
    // (literals included) in error messages and the CLI keeps a history, so a
    // password given in SQL leaks. The password is read from an environment
    // variable; `password_env` only chooses which one.
    duck("duckdb_table_function_add_named_parameter")(tf, "password_env", vt);
    // 'password' (default) | 'external' (wallet, Kerberos, OS authentication)
    duck("duckdb_table_function_add_named_parameter")(tf, "auth", vt);
    // 'double' (default, checked) | 'lossy_double' | 'varchar': see column.NumberMode
    duck("duckdb_table_function_add_named_parameter")(tf, "unconstrained_number", vt);

    // Seconds; 0 disables. See timeouts.zig for why these exist.
    var vi = logicalType(c.DUCKDB_TYPE_BIGINT);
    defer duck("duckdb_destroy_logical_type")(&vi);
    duck("duckdb_table_function_add_named_parameter")(tf, "connect_timeout", vi);
    duck("duckdb_table_function_add_named_parameter")(tf, "timeout", vi);

    duck("duckdb_table_function_set_bind")(tf, queryBind);
    duck("duckdb_table_function_set_init")(tf, queryInit);
    duck("duckdb_table_function_set_function")(tf, queryFunction);
    return duck("duckdb_register_table_function")(conn, tf) == c.DuckDBSuccess;
}

fn registerClientInfo(conn: c.duckdb_connection) bool {
    var tf = duck("duckdb_create_table_function")();
    defer duck("duckdb_destroy_table_function")(&tf);
    duck("duckdb_table_function_set_name")(tf, "oracle_client_info");
    duck("duckdb_table_function_set_bind")(tf, infoBind);
    duck("duckdb_table_function_set_init")(tf, infoInit);
    duck("duckdb_table_function_set_function")(tf, infoFunction);
    return duck("duckdb_register_table_function")(conn, tf) == c.DuckDBSuccess;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Copy a DuckDB VARCHAR value into an owned slice; null for SQL NULL.
fn valueToOwned(v: c.duckdb_value) ?[]u8 {
    if (duck("duckdb_is_null_value")(v)) return null;
    const s = duck("duckdb_get_varchar")(v) orelse return null;
    defer duck("duckdb_free")(s);
    return alloc.dupe(u8, std.mem.span(s)) catch null;
}

fn namedParam(info: c.duckdb_bind_info, name: [*:0]const u8) ?[]u8 {
    var v = duck("duckdb_bind_get_named_parameter")(info, name);
    if (v == null) return null;
    defer duck("duckdb_destroy_value")(&v);
    return valueToOwned(v);
}

/// True when the named parameter was supplied in the SQL (even as NULL).
fn hasNamedParam(info: c.duckdb_bind_info, name: [*:0]const u8) bool {
    var v = duck("duckdb_bind_get_named_parameter")(info, name);
    if (v == null) return false;
    duck("duckdb_destroy_value")(&v);
    return true;
}

/// Named BIGINT parameter holding a number of seconds in [0, max_call_secs].
fn secondsParam(info: c.duckdb_bind_info, msg: *Msg, comptime name: [:0]const u8, default: u32) !u32 {
    var v = duck("duckdb_bind_get_named_parameter")(info, name.ptr);
    if (v == null) return default;
    defer duck("duckdb_destroy_value")(&v);
    if (duck("duckdb_is_null_value")(v)) {
        msg.set("duckdb_oracle: oracle_query: " ++ name ++ " must not be NULL", .{});
        return error.Bind;
    }
    const n = duck("duckdb_get_int64")(v);
    if (n < 0 or n > timeouts.max_call_secs) {
        msg.set("duckdb_oracle: oracle_query: " ++ name ++ " must be between 0 and {d} seconds (0 = no limit), got {d}", .{ timeouts.max_call_secs, n });
        return error.Bind;
    }
    return @intCast(n);
}

fn positionalParam(info: c.duckdb_bind_info, idx: u64) ?[]u8 {
    var v = duck("duckdb_bind_get_parameter")(info, idx);
    if (v == null) return null;
    defer duck("duckdb_destroy_value")(&v);
    return valueToOwned(v);
}

fn setInvalid(vec: c.duckdb_vector, row: u64) void {
    duck("duckdb_vector_ensure_validity_writable")(vec);
    const validity = duck("duckdb_vector_get_validity")(vec);
    duck("duckdb_validity_set_row_invalid")(validity, row);
}

fn assignString(vec: c.duckdb_vector, row: u64, s: []const u8) void {
    duck("duckdb_vector_assign_string_element_len")(vec, row, if (s.len == 0) "" else s.ptr, s.len);
}

// ---------------------------------------------------------------------------
// oracle_query
// ---------------------------------------------------------------------------

/// Upper bound for the ODPI-C fetch buffers of one batch.
const fetch_budget_bytes: u64 = 64 << 20;

const QueryBind = struct {
    session: ?session_mod.Session = null,
    sql: []u8 = &.{},
    plans: []column.Column = &.{},
    /// Oracle column names, for error messages
    names: [][]u8 = &.{},
    vector_size: u32,
    /// rows per ODPI-C array fetch (== vector_size unless rows are very wide)
    fetch_rows: u32 = 0,

    fn destroy(self: *QueryBind) void {
        if (self.session) |sess| sess.close();
        alloc.free(self.sql);
        alloc.free(self.plans);
        for (self.names) |n| alloc.free(n);
        alloc.free(self.names);
        alloc.destroy(self);
    }
};

fn destroyQueryBind(p: ?*anyopaque) callconv(.c) void {
    if (p) |ptr| @as(*QueryBind, @ptrCast(@alignCast(ptr))).destroy();
}

fn queryBind(info: c.duckdb_bind_info) callconv(.c) void {
    var msg: Msg = .{};
    queryBindImpl(info, &msg) catch {
        duck("duckdb_bind_set_error")(info, msg.z());
    };
}

fn queryBindImpl(info: c.duckdb_bind_info, msg: *Msg) !void {
    const dsn = positionalParam(info, 0) orelse {
        msg.set("duckdb_oracle: oracle_query: dsn must not be NULL", .{});
        return error.Bind;
    };
    defer alloc.free(dsn);
    const sql = positionalParam(info, 1) orelse {
        msg.set("duckdb_oracle: oracle_query: sql must not be NULL", .{});
        return error.Bind;
    };
    defer alloc.free(sql);
    // pure checks first: they need no server and fail fast
    const sql_prepared = session_mod.prepareSql(alloc, sql) catch |e| {
        session_mod.explainSqlError(e, msg);
        return error.Bind;
    };
    defer alloc.free(sql_prepared);

    // Credentials: `user := ...`, `password_env := ...`, `auth := ...` (session.zig applies the policy)
    const user_param = namedParam(info, "user");
    defer if (user_param) |u| alloc.free(u);
    var pw_env_param: ?[]u8 = null;
    defer if (pw_env_param) |v| alloc.free(v);
    if (hasNamedParam(info, "password_env")) {
        pw_env_param = namedParam(info, "password_env") orelse {
            msg.set("duckdb_oracle: oracle_query: password_env must not be NULL", .{});
            return error.Bind;
        };
    }
    var auth: session_mod.Auth = .password;
    if (hasNamedParam(info, "auth")) {
        const given = namedParam(info, "auth") orelse {
            msg.set("duckdb_oracle: oracle_query: auth must not be NULL", .{});
            return error.Bind;
        };
        defer alloc.free(given);
        auth = session_mod.Auth.parse(given) orelse {
            msg.set("duckdb_oracle: oracle_query: auth must be 'password' or 'external', got '{s}'", .{given});
            return error.Bind;
        };
    }

    var number_mode: column.NumberMode = .double;
    if (hasNamedParam(info, "unconstrained_number")) {
        const given = namedParam(info, "unconstrained_number") orelse {
            msg.set("duckdb_oracle: oracle_query: unconstrained_number must not be NULL", .{});
            return error.Bind;
        };
        defer alloc.free(given);
        number_mode = column.NumberMode.parse(given) orelse {
            msg.set("duckdb_oracle: oracle_query: unconstrained_number must be 'double', 'lossy_double' or 'varchar', got '{s}'", .{given});
            return error.Bind;
        };
    }

    const connect_secs = try secondsParam(info, msg, "connect_timeout", timeouts.default_connect_secs);
    const call_secs = try secondsParam(info, msg, "timeout", timeouts.default_call_secs);

    const sess = try session_mod.Session.open(alloc, .{
        .dsn = dsn,
        .creds = .{ .user = user_param, .password_env = pw_env_param, .auth = auth },
        .connect_secs = connect_secs,
        .call_secs = call_secs,
    }, msg);

    const bind = alloc.create(QueryBind) catch {
        sess.close();
        return error.OutOfMemory;
    };
    bind.* = .{ .session = sess, .vector_size = @intCast(@min(duck("duckdb_vector_size")(), std.math.maxInt(u32))) };
    var bind_owned = true;
    defer if (bind_owned) bind.destroy();

    var desc = try sess.describe(alloc, sql_prepared, msg);
    defer desc.deinit(alloc);
    const ncols: u32 = @intCast(desc.columns.len);

    bind.plans = try alloc.alloc(column.Column, ncols);
    bind.names = try alloc.alloc([]u8, ncols);
    @memset(bind.names, &.{}); // destroy() frees every entry, also after a partial failure
    for (desc.columns, 0..) |ci, col| {
        const name = ci.name;
        const plan = column.fromTypeInfo(&ci.type_info, .{ .number = number_mode }) catch {
            msg.set("duckdb_oracle: column {d} (\"{s}\") has unsupported Oracle type {s}; convert it in the query, e.g. TO_CHAR(...) or JSON_SERIALIZE(...) (native JSON needs Instant Client 21c+, VECTOR/BOOLEAN need 23ai+)", .{ col + 1, name, column.oracleTypeName(ci.type_info.oracleTypeNum) });
            return error.Bind;
        };
        bind.plans[col] = plan;
        bind.names[col] = try alloc.dupe(u8, name);

        var lt = columnLogicalType(&plan);
        defer duck("duckdb_destroy_logical_type")(&lt);
        const namez = try compat.dupeZ(alloc, if (name.len == 0) "column" else name);
        defer alloc.free(namez);
        duck("duckdb_bind_add_result_column")(info, namez.ptr, lt);
    }

    bind.fetch_rows = column.fetchRows(bind.plans, bind.vector_size, fetch_budget_bytes);
    bind.sql = desc.sql; // the normalised statement; ownership moves to the bind data
    desc.sql = &.{};
    bind_owned = false;
    duck("duckdb_bind_set_bind_data")(info, bind, destroyQueryBind);
}

fn columnLogicalType(col: *const column.Column) c.duckdb_logical_type {
    const spec = col.logicalSpec();
    if (spec.child) |child_id| {
        var child = logicalType(child_id);
        defer duck("duckdb_destroy_logical_type")(&child);
        return duck("duckdb_create_list_type")(child);
    }
    if (spec.id == c.DUCKDB_TYPE_DECIMAL) return duck("duckdb_create_decimal_type")(spec.width, spec.scale);
    return logicalType(spec.id);
}

/// column.zig's vector sink over a DuckDB vector.
const DuckSink = struct {
    vec: c.duckdb_vector,
    base: [*]u8,

    fn init(vec: c.duckdb_vector) ?DuckSink {
        const p = duck("duckdb_vector_get_data")(vec) orelse return null;
        return .{ .vec = vec, .base = @ptrCast(p) };
    }
    pub fn data(self: *DuckSink) [*]u8 {
        return self.base;
    }
    pub fn setNull(self: *DuckSink, row: u32) void {
        setInvalid(self.vec, row);
    }
    pub fn string(self: *DuckSink, row: u32, bytes: []const u8) void {
        assignString(self.vec, row, bytes);
    }
    pub fn listSize(self: *DuckSink) u64 {
        return duck("duckdb_list_vector_get_size")(self.vec);
    }
    pub fn listReserve(self: *DuckSink, total: u64) bool {
        return duck("duckdb_list_vector_reserve")(self.vec, total) == c.DuckDBSuccess;
    }
    pub fn listChildData(self: *DuckSink) ?[*]u8 {
        const child = duck("duckdb_list_vector_get_child")(self.vec);
        return @ptrCast(duck("duckdb_vector_get_data")(child));
    }
    pub fn listSetSize(self: *DuckSink, n: u64) void {
        _ = duck("duckdb_list_vector_set_size")(self.vec, n);
    }
};

const QueryScan = struct {
    cursor: *OdpiCursor,
    /// scratch buffer for JSON serialisation (reused across rows)
    json_buf: std.ArrayList(u8) = .empty,

    fn destroy(self: *QueryScan) void {
        self.cursor.destroy();
        self.json_buf.deinit(alloc);
        alloc.destroy(self);
    }
};

fn destroyQueryScan(p: ?*anyopaque) callconv(.c) void {
    if (p) |ptr| @as(*QueryScan, @ptrCast(@alignCast(ptr))).destroy();
}

fn queryInit(info: c.duckdb_init_info) callconv(.c) void {
    var msg: Msg = .{};
    queryInitImpl(info, &msg) catch {
        duck("duckdb_init_set_error")(info, msg.z());
    };
}

fn queryInitImpl(info: c.duckdb_init_info, msg: *Msg) !void {
    const bind: *QueryBind = @ptrCast(@alignCast(duck("duckdb_init_get_bind_data")(info) orelse {
        msg.set("duckdb_oracle: missing bind data", .{});
        return error.Init;
    }));

    const sess = bind.session orelse {
        msg.set("duckdb_oracle: missing connection", .{});
        return error.Init;
    };
    const backend: OdpiBackend = .{ .ctx = sess.ctx, .conn = sess.conn };
    const cursor = OdpiCursor.open(alloc, backend, bind.sql, bind.plans, bind.fetch_rows, msg) catch return error.Init;
    errdefer cursor.destroy();

    const scan = alloc.create(QueryScan) catch {
        msg.set("duckdb_oracle: out of memory", .{});
        return error.Init;
    };
    scan.* = .{ .cursor = cursor };

    duck("duckdb_init_set_init_data")(info, scan, destroyQueryScan);
    duck("duckdb_init_set_max_threads")(info, 1);
}

fn queryFunction(info: c.duckdb_function_info, output: c.duckdb_data_chunk) callconv(.c) void {
    var msg: Msg = .{};
    queryFunctionImpl(info, output, &msg) catch {
        duck("duckdb_data_chunk_set_size")(output, 0);
        duck("duckdb_function_set_error")(info, msg.z());
    };
}

fn queryFunctionImpl(info: c.duckdb_function_info, output: c.duckdb_data_chunk, msg: *Msg) !void {
    const bind: *QueryBind = @ptrCast(@alignCast(duck("duckdb_function_get_bind_data")(info) orelse return error.Missing));
    const scan: *QueryScan = @ptrCast(@alignCast(duck("duckdb_function_get_init_data")(info) orelse return error.Missing));
    const batch = scan.cursor.nextBatch(msg) catch return error.Fetch;
    const nrows = batch.nrows;
    const buffer_row = batch.buffer_row;
    if (nrows == 0) {
        // exhausted, failed earlier or closed: an empty chunk ends the scan
        duck("duckdb_data_chunk_set_size")(output, 0);
        scan.cursor.endBatch();
        return;
    }

    const reader: OdpiReader = .{};
    const wctx: column.Column.WriteCtx = .{ .gpa = alloc, .json_buf = &scan.json_buf };
    for (bind.plans, 0..) |*col_plan, col| {
        const vec = duck("duckdb_data_chunk_get_vector")(output, col);
        var sink = DuckSink.init(vec) orelse return error.Missing;
        const data = scan.cursor.column(col) orelse return error.Missing;
        var r: u32 = 0;
        while (r < nrows) : (r += 1) {
            const d = &data[buffer_row + r];
            col_plan.write(&sink, reader, wctx, r, d) catch |e| {
                describeWriteError(msg, bind, col, d, e);
                return error.Fetch;
            };
        }
    }
    duck("duckdb_data_chunk_set_size")(output, nrows);

    // The values were copied into DuckDB vectors; if the result is exhausted the
    // cursor gives its handles back to Oracle right away.
    scan.cursor.endBatch();
}

/// Turn a column.write failure into the DuckDB error text.
fn describeWriteError(msg: *Msg, bind: *const QueryBind, col: usize, d: *const c.dpiData, e: column.Column.WriteError) void {
    const name = bind.names[col];
    switch (e) {
        error.ReadVector => oracle.setDpiError(msg, bind.session.?.ctx, "read VECTOR"),
        error.ReadJson => oracle.setDpiError(msg, bind.session.?.ctx, "read JSON"),
        error.ReadRowid => oracle.setDpiError(msg, bind.session.?.ctx, "convert ROWID"),
        error.PrecisionLoss => {
            const b = d.value.asBytes;
            const shown: []const u8 = if (b.ptr == null) "" else b.ptr[0..@min(b.length, 64)];
            msg.set("duckdb_oracle: column {d} (\"{s}\"): NUMBER value {s} cannot be represented exactly as DOUBLE (it would be silently rounded). " ++
                "Use CAST(... AS NUMBER(38)) in the Oracle query, or pass unconstrained_number := 'varchar' (exact text) or 'lossy_double' (accept rounding)", .{ col + 1, name, shown });
        },
        error.IntervalOverflow => msg.set("duckdb_oracle: column {d} (\"{s}\"): INTERVAL YEAR TO MONTH value is outside the range of a DuckDB INTERVAL (its months must fit in 32 bits, about 178 million years)", .{ col + 1, name }),
        error.ListReserve => msg.set("duckdb_oracle: column {d} (\"{s}\"): out of memory for VECTOR", .{ col + 1, name }),
        error.VectorFormatMismatch, error.VectorTooLarge, error.InvalidSparseIndex, error.NullDimensions => msg.set("duckdb_oracle: column {d} (\"{s}\"): cannot convert VECTOR ({s})", .{ col + 1, name, @errorName(e) }),
        error.OutOfMemory, error.UnsupportedJsonNode, error.JsonTooDeep => msg.set("duckdb_oracle: column {d} (\"{s}\"): cannot serialise JSON ({s})", .{ col + 1, name, @errorName(e) }),
        else => msg.set("duckdb_oracle: column {d} (\"{s}\"): cannot convert value ({s})", .{ col + 1, name, @errorName(e) }),
    }
}

// ---------------------------------------------------------------------------
// oracle_client_info()
// ---------------------------------------------------------------------------

const info_columns = [_]struct { name: [*:0]const u8, t: c.duckdb_type }{
    .{ .name = "client_library_found", .t = c.DUCKDB_TYPE_BOOLEAN },
    .{ .name = "client_version", .t = c.DUCKDB_TYPE_VARCHAR },
    .{ .name = "client_library_path", .t = c.DUCKDB_TYPE_VARCHAR },
    .{ .name = "process_arch", .t = c.DUCKDB_TYPE_VARCHAR },
    .{ .name = "host_arch", .t = c.DUCKDB_TYPE_VARCHAR },
    .{ .name = "odpi_version", .t = c.DUCKDB_TYPE_VARCHAR },
    .{ .name = "duckdb_oracle_version", .t = c.DUCKDB_TYPE_VARCHAR },
    .{ .name = "duckdb_capi_version", .t = c.DUCKDB_TYPE_VARCHAR },
    .{ .name = "message", .t = c.DUCKDB_TYPE_VARCHAR },
};

fn infoBind(info: c.duckdb_bind_info) callconv(.c) void {
    for (info_columns) |col| {
        var lt = logicalType(col.t);
        defer duck("duckdb_destroy_logical_type")(&lt);
        duck("duckdb_bind_add_result_column")(info, col.name, lt);
    }
}

const InfoScan = struct { emitted: bool = false };

fn destroyInfoScan(p: ?*anyopaque) callconv(.c) void {
    if (p) |ptr| alloc.destroy(@as(*InfoScan, @ptrCast(@alignCast(ptr))));
}

fn infoInit(info: c.duckdb_init_info) callconv(.c) void {
    const scan = alloc.create(InfoScan) catch {
        duck("duckdb_init_set_error")(info, "duckdb_oracle: out of memory");
        return;
    };
    scan.* = .{};
    duck("duckdb_init_set_init_data")(info, scan, destroyInfoScan);
}

extern fn duckdb_oracle_oci_library_path(buf: [*]u8, buflen: usize) usize;

fn infoFunction(info: c.duckdb_function_info, output: c.duckdb_data_chunk) callconv(.c) void {
    const scan: *InfoScan = @ptrCast(@alignCast(duck("duckdb_function_get_init_data")(info) orelse {
        duck("duckdb_function_set_error")(info, "duckdb_oracle: missing init data");
        return;
    }));
    if (scan.emitted) {
        duck("duckdb_data_chunk_set_size")(output, 0);
        return;
    }
    scan.emitted = true;

    // Attempts to load OCI (lazily); never fails hard when it is missing.
    const ci = oracle.clientInfo();
    var path_buf: [4096]u8 = undefined;
    const path_len = if (ci.found) duckdb_oracle_oci_library_path(&path_buf, path_buf.len) else 0;

    const vecs = struct {
        fn get(out: c.duckdb_data_chunk, i: u64) c.duckdb_vector {
            return duck("duckdb_data_chunk_get_vector")(out, i);
        }
    };
    const found_vec = vecs.get(output, 0);
    @as([*]bool, @ptrCast(@alignCast(duck("duckdb_vector_get_data")(found_vec))))[0] = ci.found;

    if (ci.found) assignString(vecs.get(output, 1), 0, ci.version[0..ci.version_len]) else setInvalid(vecs.get(output, 1), 0);
    if (path_len > 0) assignString(vecs.get(output, 2), 0, path_buf[0..path_len]) else setInvalid(vecs.get(output, 2), 0);
    assignString(vecs.get(output, 3), 0, arch.process_arch);
    if (ci.host_arch_len > 0) assignString(vecs.get(output, 4), 0, ci.host_arch[0..ci.host_arch_len]) else setInvalid(vecs.get(output, 4), 0);
    assignString(vecs.get(output, 5), 0, oracle.odpi_version);
    assignString(vecs.get(output, 6), 0, build_options.extension_version);
    assignString(vecs.get(output, 7), 0, build_options.capi_version);
    assignString(vecs.get(output, 8), 0, ci.message.slice());
    duck("duckdb_data_chunk_set_size")(output, 1);
}

// Windows: suppress Zig's own `_DllMainCRTStartup` (std/start.zig) so that the
// MinGW-w64 CRT DLL entry point (crtdll.c) is used. That one runs C static
// constructors (`__attribute__((constructor))`), which ODPI-C relies on to
// initialise its global mutex (dpiGlobal__initialize). Zig's stub entry point
// skips them, leaving a zeroed CRITICAL_SECTION that deadlocks on first use.
// Zig-version note (see src/compat.zig): needed on 0.15.x; since 0.17.0 Zig no
// longer exports its own entry point when libc is linked, so the declaration is
// inert there. It has to live in the root module, hence not in compat.zig.
pub const _DllMainCRTStartup = {};
