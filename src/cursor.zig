//! Cursor module: owns one Oracle result set from open to close.
//!
//! It owns the statement, the defined fetch variables and their data arrays, and
//! it is the only place that knows the release order and the early-close rules
//! (`LIMIT`, errors, cancellation). Callers see: `open`, `nextBatch`, `endBatch`,
//! `close`/`destroy`.
//!
//! The Oracle client library sits behind a seam: `Cursor(B)` is generic over a
//! backend `B`. Production uses `odpi_backend.zig` (ODPI-C). The tests below use
//! an in-memory backend that counts live handles and can fail at any call, which
//! lets every error path and early close be tested without an Oracle server.
//!
//! Backend interface (duck-typed; `B.Stmt`/`B.Var` are opaque handle types):
//!   prepare(sql) !Stmt                       setFetchArraySize(stmt, rows) !void
//!   execute(stmt) !u32 (column count)        newVar(plan, rows) !NewVar{ handle, data }
//!   define(stmt, pos1, var) !void            fetchRows(stmt, max) !Fetched{ buffer_row, nrows, more }
//!   releaseVar(var) void                     closeStmt(stmt) void      releaseStmt(stmt) void
//!   describeError(msg, comptime what) void   (fills `msg` from the backend's last error)
const std = @import("std");
const c = @import("c.zig").c;
const colmod = @import("column.zig");
const Msg = @import("oracle.zig").Msg;

pub const Error = error{ Open, Fetch, OutOfMemory };

/// Rows made available by one `nextBatch`. Valid until the next `nextBatch`,
/// `endBatch` or `close`.
pub const Batch = struct {
    /// index into each column's data array of the first row
    buffer_row: u32,
    nrows: u32,
};

pub fn Cursor(comptime B: type) type {
    return struct {
        const Self = @This();

        a: std.mem.Allocator,
        backend: B,
        stmt: ?B.Stmt = null,
        vars: []?B.Var = &.{},
        data: []?[*]c.dpiData = &.{},
        fetch_rows: u32,
        /// true while a result is being read; false once exhausted, failed or closed
        active: bool = true,
        /// the backend reported that no further rows exist (applied by endBatch)
        exhausted: bool = false,

        /// Prepare, execute and define one fetch variable per plan. On any failure
        /// everything acquired so far is released and `msg` describes the error.
        pub fn open(
            a: std.mem.Allocator,
            backend: B,
            sql: []const u8,
            plans: []const colmod.Column,
            fetch_rows: u32,
            msg: *Msg,
        ) Error!*Self {
            const self = a.create(Self) catch {
                msg.set("duckdb_oracle: out of memory", .{});
                return error.OutOfMemory;
            };
            self.* = .{ .a = a, .backend = backend, .fetch_rows = fetch_rows };
            errdefer self.destroy();

            self.vars = a.alloc(?B.Var, plans.len) catch {
                msg.set("duckdb_oracle: out of memory", .{});
                return error.OutOfMemory;
            };
            @memset(self.vars, null);
            self.data = a.alloc(?[*]c.dpiData, plans.len) catch {
                msg.set("duckdb_oracle: out of memory", .{});
                return error.OutOfMemory;
            };
            @memset(self.data, null);

            self.stmt = backend.prepare(sql) catch {
                backend.describeError(msg, "prepare failed");
                return error.Open;
            };
            const stmt = self.stmt.?;
            backend.setFetchArraySize(stmt, fetch_rows) catch {
                backend.describeError(msg, "set fetch array size");
                return error.Open;
            };
            const exec_cols = backend.execute(stmt) catch {
                backend.describeError(msg, "execute failed");
                return error.Open;
            };
            if (exec_cols != plans.len) {
                msg.set("duckdb_oracle: query shape changed between bind and execution ({d} vs {d} columns)", .{ plans.len, exec_cols });
                return error.Open;
            }

            for (plans, 0..) |*plan, i| {
                const nv = backend.newVar(plan, fetch_rows) catch {
                    backend.describeError(msg, "create fetch variable");
                    return error.Open;
                };
                self.vars[i] = nv.handle;
                self.data[i] = nv.data;
                backend.define(stmt, @intCast(i + 1), nv.handle) catch {
                    backend.describeError(msg, "define column");
                    return error.Open;
                };
            }
            return self;
        }

        /// Fetch the next batch of up to `fetch_rows` rows. After the result is
        /// exhausted, failed or closed this returns an empty batch. On failure the
        /// handles are released immediately and later calls return empty batches.
        pub fn nextBatch(self: *Self, msg: *Msg) Error!Batch {
            if (!self.active) return .{ .buffer_row = 0, .nrows = 0 };
            const f = self.backend.fetchRows(self.stmt.?, self.fetch_rows) catch {
                self.backend.describeError(msg, "fetch failed");
                self.close();
                return error.Fetch;
            };
            self.exhausted = !f.more;
            return .{ .buffer_row = f.buffer_row, .nrows = f.nrows };
        }

        /// The caller has finished reading the batch (strings and LOB bytes point
        /// into the fetch variables, so release must wait until here). Gives the
        /// cursor back to Oracle right away once the result is exhausted.
        pub fn endBatch(self: *Self) void {
            if (self.exhausted) self.close();
        }

        /// Column `i`'s data array; valid while `active` (between open and close).
        pub fn column(self: *const Self, i: usize) ?[*]c.dpiData {
            return self.data[i];
        }

        /// Release every backend handle, variables before the statement. Idempotent.
        pub fn close(self: *Self) void {
            for (self.vars) |*v| {
                if (v.*) |handle| self.backend.releaseVar(handle);
                v.* = null;
            }
            for (self.data) |*d| d.* = null;
            if (self.stmt) |s| {
                self.backend.closeStmt(s);
                self.backend.releaseStmt(s);
                self.stmt = null;
            }
            self.active = false;
        }

        pub fn destroy(self: *Self) void {
            self.close();
            self.a.free(self.vars);
            self.a.free(self.data);
            self.a.destroy(self);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: an in-memory backend with handle accounting and fault injection.
// ---------------------------------------------------------------------------
const testing = std.testing;

const Fake = struct {
    pub const Stmt = u32;
    pub const Var = u32;

    pub const State = struct {
        total_rows: u32,
        /// ODPI-C only knows a result is exhausted after a fetch returns fewer rows
        /// than asked for; model that (an exact multiple needs one extra empty fetch).
        more_when_full: bool = true,
        exec_cols_override: ?u32 = null,
        /// make the Nth backend call (0-based, counting every call) fail
        fail_at: ?u32 = null,
        calls: u32 = 0,
        // accounting
        open_stmts: i32 = 0,
        live_vars: i32 = 0,
        bad_release: bool = false, // released or closed something twice / unknown
        rows_served: u32 = 0,
        arrays: [8]?[]c.dpiData = .{null} ** 8,
        var_live: [8]bool = .{false} ** 8,
        next_var: u32 = 0,
        last_error_what: []const u8 = "",
    };

    st: *State,

    fn tick(self: Fake) error{Failed}!void {
        const n = self.st.calls;
        self.st.calls += 1;
        if (self.st.fail_at) |k| if (k == n) return error.Failed;
    }

    pub fn prepare(self: Fake, sql: []const u8) error{Failed}!Stmt {
        _ = sql;
        try self.tick();
        self.st.open_stmts += 1;
        return 1;
    }
    pub fn setFetchArraySize(self: Fake, stmt: Stmt, rows: u32) error{Failed}!void {
        _ = stmt;
        _ = rows;
        try self.tick();
    }
    pub fn execute(self: Fake, stmt: Stmt) error{Failed}!u32 {
        _ = stmt;
        try self.tick();
        return self.st.exec_cols_override orelse 2;
    }
    pub fn newVar(self: Fake, plan: *const colmod.Column, rows: u32) error{Failed}!struct { handle: Var, data: [*]c.dpiData } {
        _ = plan;
        try self.tick();
        const id = self.st.next_var;
        self.st.next_var += 1;
        const arr = testing.allocator.alloc(c.dpiData, rows) catch return error.Failed;
        @memset(arr, std.mem.zeroes(c.dpiData));
        self.st.arrays[id] = arr;
        self.st.var_live[id] = true;
        self.st.live_vars += 1;
        return .{ .handle = id, .data = arr.ptr };
    }
    pub fn define(self: Fake, stmt: Stmt, pos: u32, v: Var) error{Failed}!void {
        _ = stmt;
        _ = pos;
        _ = v;
        try self.tick();
    }
    pub fn fetchRows(self: Fake, stmt: Stmt, max: u32) error{Failed}!struct { buffer_row: u32, nrows: u32, more: bool } {
        _ = stmt;
        try self.tick();
        const left = self.st.total_rows - self.st.rows_served;
        const n = @min(left, max);
        var id: u32 = 0;
        while (id < self.st.next_var) : (id += 1) {
            const arr = self.st.arrays[id] orelse continue;
            if (!self.st.var_live[id]) continue;
            var r: u32 = 0;
            while (r < n) : (r += 1) {
                const row = self.st.rows_served + r;
                arr[r].isNull = @intFromBool(row % 7 == 3);
                arr[r].value.asInt64 = @as(i64, row) * 10 + id;
            }
        }
        self.st.rows_served += n;
        const more = if (self.st.more_when_full) n == max else self.st.rows_served < self.st.total_rows;
        return .{ .buffer_row = 0, .nrows = n, .more = more };
    }
    pub fn releaseVar(self: Fake, v: Var) void {
        if (v >= 8 or !self.st.var_live[v]) {
            self.st.bad_release = true;
            return;
        }
        self.st.var_live[v] = false;
        self.st.live_vars -= 1;
        testing.allocator.free(self.st.arrays[v].?);
        self.st.arrays[v] = null;
    }
    pub fn closeStmt(self: Fake, stmt: Stmt) void {
        _ = stmt;
        if (self.st.open_stmts <= 0) self.st.bad_release = true;
    }
    pub fn releaseStmt(self: Fake, stmt: Stmt) void {
        _ = stmt;
        self.st.open_stmts -= 1;
        if (self.st.open_stmts < 0) self.st.bad_release = true;
    }
    pub fn describeError(self: Fake, msg: *Msg, comptime what: []const u8) void {
        self.st.last_error_what = what;
        msg.set("duckdb_oracle: " ++ what ++ ": fake backend failure", .{});
    }
};

const FakeCursor = Cursor(Fake);

fn twoPlans() [2]colmod.Column {
    const plan: colmod.Column = .{ .kind = .bigint, .oracle_type = c.DPI_ORACLE_TYPE_NUMBER, .native_type = c.DPI_NATIVE_TYPE_INT64 };
    return .{ plan, plan };
}

fn expectClean(st: *const Fake.State) !void {
    try testing.expectEqual(@as(i32, 0), st.open_stmts);
    try testing.expectEqual(@as(i32, 0), st.live_vars);
    try testing.expect(!st.bad_release);
}

test "streams every row in batches and releases everything when exhausted" {
    var st: Fake.State = .{ .total_rows = 10 };
    const plans = twoPlans();
    var msg: Msg = .{};
    const cur = try FakeCursor.open(testing.allocator, .{ .st = &st }, "select", &plans, 4, &msg);
    defer cur.destroy();

    var seen: u32 = 0;
    var batches: u32 = 0;
    while (true) {
        const b = try cur.nextBatch(&msg);
        if (b.nrows == 0) break;
        batches += 1;
        var r: u32 = 0;
        while (r < b.nrows) : (r += 1) {
            const row = seen + r;
            const d0 = cur.column(0).?[b.buffer_row + r];
            const d1 = cur.column(1).?[b.buffer_row + r];
            try testing.expectEqual(@as(c_int, @intFromBool(row % 7 == 3)), d0.isNull);
            if (d0.isNull == 0) {
                try testing.expectEqual(@as(i64, row) * 10, d0.value.asInt64);
                try testing.expectEqual(@as(i64, row) * 10 + 1, d1.value.asInt64);
            }
        }
        seen += b.nrows;
        cur.endBatch();
    }
    try testing.expectEqual(@as(u32, 10), seen);
    try testing.expectEqual(@as(u32, 3), batches); // 4 + 4 + 2 (the short batch ends the result)
    // exhausted -> handles were given back before destroy() ran
    try expectClean(&st);
    // and a further call is empty and does not touch the backend
    const calls = st.calls;
    try testing.expectEqual(@as(u32, 0), (try cur.nextBatch(&msg)).nrows);
    try testing.expectEqual(calls, st.calls);
}

test "an exact multiple of the batch size needs one empty fetch to finish" {
    var st: Fake.State = .{ .total_rows = 8 };
    const plans = twoPlans();
    var msg: Msg = .{};
    const cur = try FakeCursor.open(testing.allocator, .{ .st = &st }, "select", &plans, 4, &msg);
    defer cur.destroy();
    var total: u32 = 0;
    while (true) {
        const b = try cur.nextBatch(&msg);
        total += b.nrows;
        cur.endBatch();
        if (b.nrows == 0) break;
    }
    try testing.expectEqual(@as(u32, 8), total);
    try expectClean(&st);
}

test "stopping early (LIMIT) releases every handle; closing twice is harmless" {
    var st: Fake.State = .{ .total_rows = 1000 };
    const plans = twoPlans();
    var msg: Msg = .{};
    const cur = try FakeCursor.open(testing.allocator, .{ .st = &st }, "select", &plans, 4, &msg);
    _ = try cur.nextBatch(&msg); // DuckDB read one chunk, then LIMIT was satisfied
    cur.endBatch();
    try testing.expectEqual(@as(i32, 1), st.open_stmts); // still open mid-scan
    cur.close();
    try expectClean(&st);
    cur.close(); // idempotent
    cur.destroy(); // and destroy after close
    try expectClean(&st);
    try testing.expectEqual(@as(u32, 4), st.rows_served); // nothing was fetched beyond the first batch
}

test "a failure at any step of open() releases everything acquired so far" {
    const plans = twoPlans();
    var fail_at: u32 = 0;
    var opened_once = false;
    while (fail_at < 40) : (fail_at += 1) {
        var st: Fake.State = .{ .total_rows = 5, .fail_at = fail_at };
        var msg: Msg = .{};
        if (FakeCursor.open(testing.allocator, .{ .st = &st }, "select", &plans, 4, &msg)) |cur| {
            opened_once = true;
            cur.destroy();
        } else |err| {
            try testing.expectEqual(error.Open, err);
            try testing.expect(std.mem.indexOf(u8, msg.slice(), "fake backend failure") != null);
        }
        try expectClean(&st); // testing.allocator also fails the test on any leaked byte
    }
    try testing.expect(opened_once); // the sweep passed the last backend call
}

test "open() reports which step failed" {
    const plans = twoPlans();
    const steps = [_][]const u8{ "prepare failed", "set fetch array size", "execute failed", "create fetch variable", "define column" };
    for (steps, 0..) |what, k| {
        var st: Fake.State = .{ .total_rows = 5, .fail_at = @intCast(k) };
        var msg: Msg = .{};
        try testing.expectError(error.Open, FakeCursor.open(testing.allocator, .{ .st = &st }, "select", &plans, 4, &msg));
        try testing.expectEqualStrings(what, st.last_error_what);
    }
}

test "a fetch failure releases the handles at once; later calls are empty; destroy is safe" {
    var st: Fake.State = .{ .total_rows = 100 };
    const plans = twoPlans();
    var msg: Msg = .{};
    const cur = try FakeCursor.open(testing.allocator, .{ .st = &st }, "select", &plans, 4, &msg);
    st.fail_at = st.calls; // the next backend call (the first fetch) fails
    try testing.expectError(error.Fetch, cur.nextBatch(&msg));
    try testing.expectEqualStrings("fetch failed", st.last_error_what);
    try expectClean(&st);
    try testing.expectEqual(@as(u32, 0), (try cur.nextBatch(&msg)).nrows);
    cur.destroy();
    try expectClean(&st);
}

test "a changed column count between describe and execute is rejected cleanly" {
    var st: Fake.State = .{ .total_rows = 5, .exec_cols_override = 3 };
    const plans = twoPlans();
    var msg: Msg = .{};
    try testing.expectError(error.Open, FakeCursor.open(testing.allocator, .{ .st = &st }, "select", &plans, 4, &msg));
    try testing.expect(std.mem.indexOf(u8, msg.slice(), "query shape changed") != null);
    try expectClean(&st);
}
