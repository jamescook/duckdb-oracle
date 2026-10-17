//! duckdb-oracle: query Oracle from DuckDB through the stable C Extension API + ODPI-C.
//!
//! SQL surface (v1):
//!   oracle_query(dsn VARCHAR, sql VARCHAR, user := VARCHAR, password_env := VARCHAR)
//!   oracle_client_info()
const std = @import("std");
const compat = @import("compat.zig");
const c = @import("c.zig").c;
const convert = @import("convert.zig");
const oracle = @import("oracle.zig");
const arch = @import("arch.zig");
const timeouts = @import("timeouts.zig");
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
    // 'double' (default, checked) | 'lossy_double' | 'varchar': see convert.NumberMode
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

fn envOwned(name: [:0]const u8) ?[]u8 {
    return compat.getEnvOwned(alloc, name);
}

fn freeSecret(s: ?[]u8) void {
    if (s) |p| {
        std.crypto.secureZero(u8, p);
        alloc.free(p);
    }
}

fn len32(s: []const u8) u32 {
    return @intCast(@min(s.len, std.math.maxInt(u32)));
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
    ctx: *c.dpiContext,
    conn: ?*c.dpiConn = null,
    sql: []u8 = &.{},
    plans: []convert.ColumnPlan = &.{},
    /// Oracle column names, for error messages
    names: [][]u8 = &.{},
    vector_size: u32,
    /// rows per ODPI-C array fetch (== vector_size unless rows are very wide)
    fetch_rows: u32 = 0,

    fn destroy(self: *QueryBind) void {
        if (self.conn) |conn| _ = c.dpiConn_release(conn);
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
    var sql_owned: ?[]u8 = sql;
    defer if (sql_owned) |s| alloc.free(s);

    const user = namedParam(info, "user") orelse envOwned("ORACLE_USER");
    defer if (user) |u| alloc.free(u);

    // Name of the environment variable that holds the password.
    var pw_var_owned: ?[:0]u8 = null;
    defer if (pw_var_owned) |v| alloc.free(v);
    var pw_var: [:0]const u8 = "ORACLE_PASSWORD";
    if (hasNamedParam(info, "password_env")) {
        const given = namedParam(info, "password_env") orelse {
            msg.set("duckdb_oracle: oracle_query: password_env must not be NULL", .{});
            return error.Bind;
        };
        defer alloc.free(given);
        pw_var_owned = try compat.dupeZ(alloc, given);
        pw_var = pw_var_owned.?;
    }
    const password = envOwned(pw_var);
    defer freeSecret(password);

    if (user == null or user.?.len == 0) {
        msg.set("duckdb_oracle: oracle_query: no user given; pass user := '...' or set the ORACLE_USER environment variable", .{});
        return error.Bind;
    }
    if (password == null or password.?.len == 0) {
        msg.set("duckdb_oracle: oracle_query: no password given: the environment variable {s} is empty or not set (passwords are never accepted as SQL arguments; password_env := 'NAME' selects another variable)", .{pw_var});
        return error.Bind;
    }

    var number_mode: convert.NumberMode = .double;
    if (hasNamedParam(info, "unconstrained_number")) {
        const given = namedParam(info, "unconstrained_number") orelse {
            msg.set("duckdb_oracle: oracle_query: unconstrained_number must not be NULL", .{});
            return error.Bind;
        };
        defer alloc.free(given);
        number_mode = convert.NumberMode.parse(given) orelse {
            msg.set("duckdb_oracle: oracle_query: unconstrained_number must be 'double', 'lossy_double' or 'varchar', got '{s}'", .{given});
            return error.Bind;
        };
    }

    const connect_secs = try secondsParam(info, msg, "connect_timeout", timeouts.default_connect_secs);
    const call_secs = try secondsParam(info, msg, "timeout", timeouts.default_call_secs);

    // First Oracle use in this process loads OCI here.
    const ctx = oracle.getContext(msg) orelse {
        const tmp = msg.*;
        var hb: [768]u8 = undefined;
        const h = oracle.archHint(&hb, false);
        if (h.len > 0)
            msg.set("duckdb_oracle: Oracle client library could not be loaded: {s} | hint: {s}", .{ tmp.slice(), h })
        else
            msg.set("duckdb_oracle: Oracle client library could not be loaded: {s}", .{tmp.slice()});
        return error.Bind;
    };

    const bind = try alloc.create(QueryBind);
    bind.* = .{ .ctx = ctx, .vector_size = @intCast(@min(duck("duckdb_vector_size")(), std.math.maxInt(u32))) };
    var bind_owned = true;
    defer if (bind_owned) bind.destroy();

    var common = std.mem.zeroes(c.dpiCommonCreateParams);
    if (c.dpiContext_initCommonCreateParams(ctx, &common) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "init connection parameters");
        return error.Bind;
    }
    common.createMode = c.DPI_MODE_CREATE_THREADED;
    common.encoding = "UTF-8";
    common.nencoding = "UTF-8";

    const connect_dsn = try timeouts.withConnectTimeout(alloc, dsn, connect_secs);
    defer alloc.free(connect_dsn);

    var conn: ?*c.dpiConn = null;
    if (c.dpiConn_create(ctx, user.?.ptr, len32(user.?), password.?.ptr, len32(password.?), connect_dsn.ptr, len32(connect_dsn), &common, null, &conn) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "connect failed");
        return error.Bind;
    }
    bind.conn = conn;

    // Bounds every later round trip on this session (describe, execute, each fetch).
    if (call_secs > 0 and c.dpiConn_setCallTimeout(conn, timeouts.callTimeoutMs(call_secs)) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "set call timeout");
        return error.Bind;
    }

    // Describe the query without executing it.
    var stmt: ?*c.dpiStmt = null;
    if (c.dpiConn_prepareStmt(conn, 0, sql.ptr, len32(sql), null, 0, &stmt) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "prepare failed");
        return error.Bind;
    }
    defer _ = c.dpiStmt_release(stmt);

    var sinfo = std.mem.zeroes(c.dpiStmtInfo);
    if (c.dpiStmt_getInfo(stmt, &sinfo) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "statement info");
        return error.Bind;
    }
    // Never run DDL/DML/PL/SQL: OCI executes DDL even in describe-only mode.
    if (sinfo.isQuery == 0) {
        msg.set("duckdb_oracle: oracle_query only runs queries (SELECT / WITH); writes, DDL and PL/SQL are not supported", .{});
        return error.Bind;
    }

    var ncols: u32 = 0;
    if (c.dpiStmt_execute(stmt, c.DPI_MODE_EXEC_DESCRIBE_ONLY, &ncols) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "describe failed");
        return error.Bind;
    }
    if (ncols == 0) {
        msg.set("duckdb_oracle: oracle_query: the query returns no columns", .{});
        return error.Bind;
    }

    bind.plans = try alloc.alloc(convert.ColumnPlan, ncols);
    bind.names = try alloc.alloc([]u8, ncols);
    @memset(bind.names, &.{}); // destroy() frees every entry, also after a partial failure
    var col: u32 = 0;
    while (col < ncols) : (col += 1) {
        var qi = std.mem.zeroes(c.dpiQueryInfo);
        if (c.dpiStmt_getQueryInfo(stmt, col + 1, &qi) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, ctx, "describe column");
            return error.Bind;
        }
        const name: []const u8 = if (qi.name) |n| n[0..qi.nameLength] else "";
        const plan = convert.planColumnOpts(&qi.typeInfo, .{ .number = number_mode }) catch {
            msg.set("duckdb_oracle: column {d} (\"{s}\") has unsupported Oracle type {s}; convert it in the query, e.g. TO_CHAR(...) or JSON_SERIALIZE(...) (native JSON needs Instant Client 21c+, VECTOR/BOOLEAN need 23ai+)", .{ col + 1, name, convert.oracleTypeName(qi.typeInfo.oracleTypeNum) });
            return error.Bind;
        };
        bind.plans[col] = plan;
        bind.names[col] = try alloc.dupe(u8, name);

        var lt = planLogicalType(&plan);
        defer duck("duckdb_destroy_logical_type")(&lt);
        const namez = try compat.dupeZ(alloc, if (name.len == 0) "column" else name);
        defer alloc.free(namez);
        duck("duckdb_bind_add_result_column")(info, namez.ptr, lt);
    }

    bind.fetch_rows = convert.fetchRows(bind.plans, bind.vector_size, fetch_budget_bytes);
    bind.sql = sql;
    sql_owned = null;
    bind_owned = false;
    duck("duckdb_bind_set_bind_data")(info, bind, destroyQueryBind);
}

fn planLogicalType(plan: *const convert.ColumnPlan) c.duckdb_logical_type {
    return switch (plan.kind) {
        .decimal => duck("duckdb_create_decimal_type")(plan.width, plan.scale),
        .list => blk: {
            var child = logicalType(plan.list_elem.duckdbType());
            defer duck("duckdb_destroy_logical_type")(&child);
            break :blk duck("duckdb_create_list_type")(child);
        },
        else => logicalType(plan.kind.duckdbType()),
    };
}

const QueryScan = struct {
    stmt: ?*c.dpiStmt = null,
    vars: []?*c.dpiVar,
    data: []?[*]c.dpiData,
    done: bool = false,
    /// scratch buffer for JSON serialisation (reused across rows)
    json_buf: std.ArrayList(u8) = .empty,

    fn destroy(self: *QueryScan) void {
        self.release();
        self.json_buf.deinit(alloc);
        alloc.free(self.vars);
        alloc.free(self.data);
        alloc.destroy(self);
    }

    /// Free all ODPI-C handles (also used as soon as the result is exhausted).
    fn release(self: *QueryScan) void {
        for (self.vars) |*v| {
            if (v.*) |handle| _ = c.dpiVar_release(handle);
            v.* = null;
        }
        if (self.stmt) |s| {
            _ = c.dpiStmt_close(s, null, 0);
            _ = c.dpiStmt_release(s);
            self.stmt = null;
        }
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
    const ctx = bind.ctx;
    const ncols: u32 = @intCast(bind.plans.len);

    const scan = alloc.create(QueryScan) catch {
        msg.set("duckdb_oracle: out of memory", .{});
        return error.Init;
    };
    scan.* = .{ .vars = &.{}, .data = &.{} };
    var scan_owned = true;
    defer if (scan_owned) scan.destroy();
    scan.vars = alloc.alloc(?*c.dpiVar, ncols) catch {
        msg.set("duckdb_oracle: out of memory", .{});
        return error.Init;
    };
    @memset(scan.vars, null);
    scan.data = alloc.alloc(?[*]c.dpiData, ncols) catch {
        msg.set("duckdb_oracle: out of memory", .{});
        return error.Init;
    };
    @memset(scan.data, null);

    if (c.dpiConn_prepareStmt(bind.conn, 0, bind.sql.ptr, len32(bind.sql), null, 0, &scan.stmt) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "prepare failed");
        return error.Init;
    }
    if (c.dpiStmt_setFetchArraySize(scan.stmt, bind.fetch_rows) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "set fetch array size");
        return error.Init;
    }
    var exec_cols: u32 = 0;
    if (c.dpiStmt_execute(scan.stmt, c.DPI_MODE_EXEC_DEFAULT, &exec_cols) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, ctx, "execute failed");
        return error.Init;
    }
    if (exec_cols != ncols) {
        msg.set("duckdb_oracle: query shape changed between bind and execution ({d} vs {d} columns)", .{ ncols, exec_cols });
        return error.Init;
    }

    for (bind.plans, 0..) |*plan, i| {
        var data: [*c]c.dpiData = null;
        if (c.dpiConn_newVar(bind.conn, plan.oracle_type, plan.native_type, bind.fetch_rows, plan.size, @intFromBool(plan.size_is_bytes), 0, null, &scan.vars[i], &data) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, ctx, "create fetch variable");
            return error.Init;
        }
        scan.data[i] = data;
        if (c.dpiStmt_define(scan.stmt, @intCast(i + 1), scan.vars[i]) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, ctx, "define column");
            return error.Init;
        }
    }

    scan_owned = false;
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
    if (scan.done or scan.stmt == null) {
        duck("duckdb_data_chunk_set_size")(output, 0);
        return;
    }

    var buffer_row: u32 = 0;
    var nrows: u32 = 0;
    var more: c_int = 0;
    if (c.dpiStmt_fetchRows(scan.stmt, bind.fetch_rows, &buffer_row, &nrows, &more) != c.DPI_SUCCESS) {
        oracle.setDpiError(msg, bind.ctx, "fetch failed");
        scan.release();
        scan.done = true;
        return error.Fetch;
    }

    for (bind.plans, 0..) |*plan, col| {
        const vec = duck("duckdb_data_chunk_get_vector")(output, col);
        const out: [*]u8 = @ptrCast(duck("duckdb_vector_get_data")(vec) orelse return error.Missing);
        const data = scan.data[col] orelse return error.Missing;
        // LIST (VECTOR) state
        const child: c.duckdb_vector = if (plan.kind == .list) duck("duckdb_list_vector_get_child")(vec) else null;
        var list_size: u64 = if (plan.kind == .list) duck("duckdb_list_vector_get_size")(vec) else 0;
        const entries: [*]c.duckdb_list_entry = @ptrCast(@alignCast(out));
        var r: u32 = 0;
        while (r < nrows) : (r += 1) {
            const d = &data[buffer_row + r];
            if (d.isNull != 0) {
                if (plan.kind == .list) entries[r] = .{ .offset = list_size, .length = 0 };
                setInvalid(vec, r);
                continue;
            }
            switch (plan.kind) {
                .list => {
                    var vi = std.mem.zeroes(c.dpiVectorInfo);
                    if (c.dpiVector_getValue(d.value.asVector, &vi) != c.DPI_SUCCESS) {
                        oracle.setDpiError(msg, bind.ctx, "read VECTOR");
                        return error.Fetch;
                    }
                    const n = convert.vectorLen(&vi, plan.list_elem) catch |e| {
                        msg.set("duckdb_oracle: column {d}: cannot convert VECTOR ({s})", .{ col + 1, @errorName(e) });
                        return error.Fetch;
                    };
                    if (duck("duckdb_list_vector_reserve")(vec, list_size + n) != c.DuckDBSuccess) {
                        msg.set("duckdb_oracle: column {d}: out of memory for VECTOR", .{col + 1});
                        return error.Fetch;
                    }
                    const child_data: [*]u8 = @ptrCast(duck("duckdb_vector_get_data")(child) orelse return error.Missing);
                    convert.convertVector(&vi, plan.list_elem, child_data + list_size * plan.list_elem.size()) catch |e| {
                        msg.set("duckdb_oracle: column {d}: cannot convert VECTOR ({s})", .{ col + 1, @errorName(e) });
                        return error.Fetch;
                    };
                    entries[r] = .{ .offset = list_size, .length = n };
                    list_size += n;
                    _ = duck("duckdb_list_vector_set_size")(vec, list_size);
                },
                .varchar, .blob => {
                    if (plan.is_json) {
                        var top: [*c]c.dpiJsonNode = null;
                        if (c.dpiJson_getValue(d.value.asJson, convert.json_get_options, &top) != c.DPI_SUCCESS or top == null) {
                            oracle.setDpiError(msg, bind.ctx, "read JSON");
                            return error.Fetch;
                        }
                        scan.json_buf.clearRetainingCapacity();
                        convert.serializeJson(alloc, &scan.json_buf, @ptrCast(top)) catch |e| {
                            msg.set("duckdb_oracle: column {d}: cannot serialise JSON ({s})", .{ col + 1, @errorName(e) });
                            return error.Fetch;
                        };
                        assignString(vec, r, scan.json_buf.items);
                    } else if (plan.is_rowid) {
                        var p: [*c]const u8 = null;
                        var l: u32 = 0;
                        if (c.dpiRowid_getStringValue(d.value.asRowid, &p, &l) != c.DPI_SUCCESS) {
                            oracle.setDpiError(msg, bind.ctx, "convert ROWID");
                            return error.Fetch;
                        }
                        assignString(vec, r, if (p == null) "" else p[0..l]);
                    } else {
                        const b = d.value.asBytes;
                        assignString(vec, r, if (b.ptr == null) "" else b.ptr[0..b.length]);
                    }
                },
                else => convert.storeFixed(plan, &d.value, out, r) catch |e| {
                    if (e == error.PrecisionLoss) {
                        const b = d.value.asBytes;
                        const shown: []const u8 = if (b.ptr == null) "" else b.ptr[0..@min(b.length, 64)];
                        msg.set("duckdb_oracle: column {d} (\"{s}\"): NUMBER value {s} cannot be represented exactly as DOUBLE (it would be silently rounded). " ++
                            "Use CAST(... AS NUMBER(38)) in the Oracle query, or pass unconstrained_number := 'varchar' (exact text) or 'lossy_double' (accept rounding)", .{ col + 1, bind.names[col], shown });
                    } else {
                        msg.set("duckdb_oracle: column {d}: cannot convert value ({s})", .{ col + 1, @errorName(e) });
                    }
                    return error.Fetch;
                },
            }
        }
    }
    duck("duckdb_data_chunk_set_size")(output, nrows);

    if (more == 0) {
        // Result exhausted: give the cursor back to Oracle right away.
        scan.release();
        scan.done = true;
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

test {
    _ = convert;
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
