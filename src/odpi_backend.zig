//! Production backend for cursor.zig: the ODPI-C calls, and nothing else.
//! (The in-memory backend used by the tests lives in cursor.zig.)
const std = @import("std");
const c = @import("c.zig").c;
const convert = @import("convert.zig");
const oracle = @import("oracle.zig");

pub const OdpiBackend = struct {
    pub const Stmt = *c.dpiStmt;
    pub const Var = *c.dpiVar;
    pub const Error = error{Failed};

    ctx: *c.dpiContext,
    conn: *c.dpiConn,

    fn ok(rc: c_int) Error!void {
        if (rc != c.DPI_SUCCESS) return error.Failed;
    }

    fn len32(s: []const u8) u32 {
        return @intCast(@min(s.len, std.math.maxInt(u32)));
    }

    pub fn prepare(self: OdpiBackend, sql: []const u8) Error!Stmt {
        var stmt: ?*c.dpiStmt = null;
        try ok(c.dpiConn_prepareStmt(self.conn, 0, sql.ptr, len32(sql), null, 0, &stmt));
        return stmt orelse error.Failed;
    }

    pub fn setFetchArraySize(self: OdpiBackend, stmt: Stmt, rows: u32) Error!void {
        _ = self;
        try ok(c.dpiStmt_setFetchArraySize(stmt, rows));
    }

    pub fn execute(self: OdpiBackend, stmt: Stmt) Error!u32 {
        _ = self;
        var cols: u32 = 0;
        try ok(c.dpiStmt_execute(stmt, c.DPI_MODE_EXEC_DEFAULT, &cols));
        return cols;
    }

    pub fn newVar(self: OdpiBackend, plan: *const convert.ColumnPlan, rows: u32) Error!struct { handle: Var, data: [*]c.dpiData } {
        var v: ?*c.dpiVar = null;
        var data: [*c]c.dpiData = null;
        try ok(c.dpiConn_newVar(self.conn, plan.oracle_type, plan.native_type, rows, plan.size, @intFromBool(plan.size_is_bytes), 0, null, &v, &data));
        // data is non-null whenever the call succeeded
        return .{ .handle = v orelse return error.Failed, .data = data orelse return error.Failed };
    }

    pub fn define(self: OdpiBackend, stmt: Stmt, pos: u32, v: Var) Error!void {
        _ = self;
        try ok(c.dpiStmt_define(stmt, pos, v));
    }

    pub fn fetchRows(self: OdpiBackend, stmt: Stmt, max: u32) Error!struct { buffer_row: u32, nrows: u32, more: bool } {
        _ = self;
        var buffer_row: u32 = 0;
        var nrows: u32 = 0;
        var more: c_int = 0;
        try ok(c.dpiStmt_fetchRows(stmt, max, &buffer_row, &nrows, &more));
        return .{ .buffer_row = buffer_row, .nrows = nrows, .more = more != 0 };
    }

    pub fn releaseVar(self: OdpiBackend, v: Var) void {
        _ = self;
        _ = c.dpiVar_release(v);
    }

    pub fn closeStmt(self: OdpiBackend, stmt: Stmt) void {
        _ = self;
        _ = c.dpiStmt_close(stmt, null, 0);
    }

    pub fn releaseStmt(self: OdpiBackend, stmt: Stmt) void {
        _ = self;
        _ = c.dpiStmt_release(stmt);
    }

    pub fn describeError(self: OdpiBackend, msg: *oracle.Msg, comptime what: []const u8) void {
        oracle.setDpiError(msg, self.ctx, what);
    }
};
