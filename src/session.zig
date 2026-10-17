//! Session module: everything about getting a ready, safe Oracle session for one
//! `oracle_query` call, behind one interface:
//!
//!   Session.open(params)      credentials, OCI load, connect, timeouts
//!   Session.describe(sql)     read-only guard, statement type, column list
//!   Session.close()
//!
//! The policy that decides what is allowed is pure and tested here (credential
//! resolution, authentication mode, SQL normalisation and the read-only guard);
//! the ODPI-C calls that carry it out are at the bottom of the file and are
//! exercised through the real Oracle client (connect failures) because no Oracle
//! server is available to the tests.
const std = @import("std");
const c = @import("c.zig").c;
const compat = @import("compat.zig");
const oracle = @import("oracle.zig");
const timeouts = @import("timeouts.zig");
const Msg = oracle.Msg;

pub const Error = error{ Bind, OutOfMemory };

// ---------------------------------------------------------------------------
// Authentication mode and credentials (pure)
// ---------------------------------------------------------------------------

pub const Auth = enum {
    /// user name + password (the default)
    password,
    /// Oracle wallet, Kerberos, OS authentication: no user name or password
    external,

    pub fn parse(text: []const u8) ?Auth {
        // an explicit table: @typeInfo's enum layout differs between Zig 0.15 and 0.17
        const names = [_]struct { []const u8, Auth }{ .{ "password", .password }, .{ "external", .external } };
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(text, n[0])) return n[1];
        }
        return null;
    }
};

pub const default_user_env = "ORACLE_USER";
pub const default_password_env = "ORACLE_PASSWORD";

/// What the SQL statement said about credentials.
pub const CredentialParams = struct {
    /// `user := ...` (null when not given)
    user: ?[]const u8 = null,
    /// `password_env := ...` (null when not given)
    password_env: ?[]const u8 = null,
    auth: Auth = .password,
};

pub const Credentials = struct {
    user: ?[]u8 = null,
    password: ?[]u8 = null,

    /// Zeroes the secret before freeing it.
    pub fn deinit(self: *Credentials, a: std.mem.Allocator) void {
        if (self.user) |u| a.free(u);
        if (self.password) |p| {
            std.crypto.secureZero(u8, p);
            a.free(p);
        }
        self.* = .{};
    }
};

/// Resolve credentials. `env.get(a, name)` returns an owned copy of an environment
/// variable or null. Failures set `msg` and return error.Bind.
pub fn resolveCredentials(a: std.mem.Allocator, env: anytype, p: CredentialParams, msg: *Msg) Error!Credentials {
    if (p.auth == .external) {
        if (p.user != null or p.password_env != null) {
            msg.set("duckdb_oracle: oracle_query: auth := 'external' takes no user or password_env (the wallet or the operating system supplies the identity)", .{});
            return error.Bind;
        }
        return .{};
    }

    var creds: Credentials = .{};
    errdefer creds.deinit(a);

    if (p.user) |u| {
        creds.user = try a.dupe(u8, u);
    } else {
        creds.user = env.get(a, default_user_env);
    }
    if (creds.user == null or creds.user.?.len == 0) {
        msg.set("duckdb_oracle: oracle_query: no user given; pass user := '...' or set the ORACLE_USER environment variable (or use auth := 'external')", .{});
        return error.Bind;
    }

    const var_name: []const u8 = p.password_env orelse default_password_env;
    const var_z = try compat.dupeZ(a, var_name);
    defer a.free(var_z);
    creds.password = env.get(a, var_z);
    if (creds.password == null or creds.password.?.len == 0) {
        msg.set("duckdb_oracle: oracle_query: no password given: the environment variable {s} is empty or not set (passwords are never accepted as SQL arguments; password_env := 'NAME' selects another variable)", .{var_name});
        return error.Bind;
    }
    return creds;
}

// ---------------------------------------------------------------------------
// SQL normalisation and the read-only guard (pure)
// ---------------------------------------------------------------------------

pub const SqlError = error{ EmptySql, ForUpdate, OutOfMemory };

/// Owned copy of `sql` that is safe to describe and run: surrounding whitespace
/// and ONE trailing semicolon removed (Oracle rejects it with ORA-00911, a common
/// habit from other tools), and statements that take row locks refused.
pub fn prepareSql(a: std.mem.Allocator, sql: []const u8) SqlError![]u8 {
    var t = std.mem.trim(u8, sql, " \t\r\n");
    if (t.len > 0 and t[t.len - 1] == ';') t = std.mem.trimEnd(u8, t[0 .. t.len - 1], " \t\r\n");
    if (t.len == 0) return error.EmptySql;
    if (hasForUpdate(t)) return error.ForUpdate;
    return a.dupe(u8, t);
}

/// Fill `msg` for a failed `prepareSql`. Run it before connecting: it needs no server.
pub fn explainSqlError(e: SqlError, msg: *Msg) void {
    switch (e) {
        error.EmptySql => msg.set("duckdb_oracle: oracle_query: sql must not be empty", .{}),
        error.ForUpdate => msg.set("duckdb_oracle: oracle_query does not run SELECT ... FOR UPDATE: it takes row locks that would stay held until the session ends (the session lives as long as the query plan)", .{}),
        error.OutOfMemory => msg.set("duckdb_oracle: out of memory", .{}),
    }
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$' or ch == '#';
}

/// True when the statement contains the keyword pair FOR UPDATE outside string
/// literals, quoted identifiers and comments. SELECT ... FOR UPDATE is a query to
/// OCI but takes row locks that stay until the session ends, and the session
/// lives as long as the plan.
pub fn hasForUpdate(sql: []const u8) bool {
    var i: usize = 0;
    var pending_for = false;
    while (i < sql.len) {
        const ch = sql[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
        } else if (ch == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            while (i < sql.len and sql[i] != '\n') i += 1;
        } else if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            i += 2;
            while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) i += 1;
            i = @min(i + 2, sql.len);
        } else if (ch == '\'') {
            i = skipQuoted(sql, i, '\'');
            pending_for = false;
        } else if (ch == '"') {
            i = skipQuoted(sql, i, '"');
            pending_for = false;
        } else if (isWordChar(ch)) {
            const start = i;
            while (i < sql.len and isWordChar(sql[i])) i += 1;
            const word = sql[start..i];
            // q'[...]' / nq'[...]': alternative quoting, delimiter chosen by the author
            if (i < sql.len and sql[i] == '\'' and (std.ascii.eqlIgnoreCase(word, "q") or std.ascii.eqlIgnoreCase(word, "nq"))) {
                i = skipAltQuoted(sql, i);
                pending_for = false;
                continue;
            }
            if (pending_for and std.ascii.eqlIgnoreCase(word, "update")) return true;
            pending_for = std.ascii.eqlIgnoreCase(word, "for");
        } else {
            i += 1;
            pending_for = false;
        }
    }
    return false;
}

/// `i` is at the opening quote; returns the index after the closing one
/// (a doubled quote is an escaped quote).
fn skipQuoted(sql: []const u8, start: usize, q: u8) usize {
    var i = start + 1;
    while (i < sql.len) : (i += 1) {
        if (sql[i] == q) {
            if (i + 1 < sql.len and sql[i + 1] == q) {
                i += 1;
                continue;
            }
            return i + 1;
        }
    }
    return sql.len;
}

/// `i` is at the quote of q'<delim>...<delim>'; returns the index after the closing quote.
fn skipAltQuoted(sql: []const u8, start: usize) usize {
    if (start + 1 >= sql.len) return sql.len;
    const open = sql[start + 1];
    const close: u8 = switch (open) {
        '[' => ']',
        '(' => ')',
        '{' => '}',
        '<' => '>',
        else => open,
    };
    var i = start + 2;
    while (i + 1 < sql.len) : (i += 1) {
        if (sql[i] == close and sql[i + 1] == '\'') return i + 2;
    }
    return sql.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

const FakeEnv = struct {
    vars: []const [2][]const u8,
    pub fn get(self: FakeEnv, a: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
        for (self.vars) |kv| if (std.mem.eql(u8, kv[0], name)) return a.dupe(u8, kv[1]) catch null;
        return null;
    }
};

fn resolveWith(vars: []const [2][]const u8, p: CredentialParams, msg: *Msg) Error!Credentials {
    return resolveCredentials(testing.allocator, FakeEnv{ .vars = vars }, p, msg);
}

test "credentials: user and password default to ORACLE_USER and ORACLE_PASSWORD" {
    var msg: Msg = .{};
    var cr = try resolveWith(&.{ .{ "ORACLE_USER", "scott" }, .{ "ORACLE_PASSWORD", "tiger" } }, .{}, &msg);
    defer cr.deinit(testing.allocator);
    try testing.expectEqualStrings("scott", cr.user.?);
    try testing.expectEqualStrings("tiger", cr.password.?);
}

test "credentials: user := overrides ORACLE_USER; password_env selects another variable" {
    var msg: Msg = .{};
    var cr = try resolveWith(&.{ .{ "ORACLE_USER", "scott" }, .{ "ORACLE_PASSWORD", "wrong" }, .{ "MY_PW", "s3cret" } }, .{ .user = "hr", .password_env = "MY_PW" }, &msg);
    defer cr.deinit(testing.allocator);
    try testing.expectEqualStrings("hr", cr.user.?);
    try testing.expectEqualStrings("s3cret", cr.password.?);
}

test "credentials: a missing or empty user is refused, naming how to give one" {
    var msg: Msg = .{};
    try testing.expectError(error.Bind, resolveWith(&.{.{ "ORACLE_PASSWORD", "x" }}, .{}, &msg));
    try testing.expect(std.mem.indexOf(u8, msg.slice(), "no user given") != null);
    try testing.expect(std.mem.indexOf(u8, msg.slice(), "auth := 'external'") != null);
    try testing.expectError(error.Bind, resolveWith(&.{ .{ "ORACLE_USER", "u" }, .{ "ORACLE_PASSWORD", "x" } }, .{ .user = "" }, &msg));
}

test "credentials: a missing or empty password names the variable that was read" {
    var msg: Msg = .{};
    try testing.expectError(error.Bind, resolveWith(&.{.{ "ORACLE_USER", "u" }}, .{ .password_env = "NOPE_PW" }, &msg));
    try testing.expect(std.mem.indexOf(u8, msg.slice(), "NOPE_PW") != null);
    try testing.expectError(error.Bind, resolveWith(&.{ .{ "ORACLE_USER", "u" }, .{ "ORACLE_PASSWORD", "" } }, .{}, &msg));
    try testing.expect(std.mem.indexOf(u8, msg.slice(), "ORACLE_PASSWORD") != null);
}

test "credentials: the error text never contains the password" {
    var msg: Msg = .{};
    try testing.expectError(error.Bind, resolveWith(&.{.{ "ORACLE_PASSWORD", "hunter2-SECRET" }}, .{}, &msg)); // no user
    try testing.expect(std.mem.indexOf(u8, msg.slice(), "hunter2-SECRET") == null);
}

test "external authentication needs no credentials and refuses user or password_env" {
    var msg: Msg = .{};
    var cr = try resolveWith(&.{}, .{ .auth = .external }, &msg);
    defer cr.deinit(testing.allocator);
    try testing.expect(cr.user == null and cr.password == null);
    try testing.expectError(error.Bind, resolveWith(&.{}, .{ .auth = .external, .user = "scott" }, &msg));
    try testing.expect(std.mem.indexOf(u8, msg.slice(), "auth := 'external'") != null);
    try testing.expectError(error.Bind, resolveWith(&.{}, .{ .auth = .external, .password_env = "X" }, &msg));
    // ORACLE_USER / ORACLE_PASSWORD in the environment are ignored in external mode
    var cr2 = try resolveWith(&.{ .{ "ORACLE_USER", "scott" }, .{ "ORACLE_PASSWORD", "tiger" } }, .{ .auth = .external }, &msg);
    defer cr2.deinit(testing.allocator);
    try testing.expect(cr2.user == null and cr2.password == null);
}

test "Auth.parse" {
    try testing.expectEqual(Auth.password, Auth.parse("password").?);
    try testing.expectEqual(Auth.external, Auth.parse("EXTERNAL").?);
    try testing.expect(Auth.parse("kerberos") == null);
}

fn prepared(sql: []const u8) ![]u8 {
    return prepareSql(testing.allocator, sql);
}

test "prepareSql: surrounding whitespace and one trailing semicolon are removed" {
    for ([_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "select 1 from dual;", .out = "select 1 from dual" },
        .{ .in = "  select 1 from dual ;  \n", .out = "select 1 from dual" },
        .{ .in = "select 1 from dual", .out = "select 1 from dual" },
        .{ .in = "select ';' from dual", .out = "select ';' from dual" }, // not a trailing semicolon
        .{ .in = "select 1 from dual;;", .out = "select 1 from dual;" }, // only one: Oracle can still object to the other
    }) |case| {
        const r = try prepared(case.in);
        defer testing.allocator.free(r);
        try testing.expectEqualStrings(case.out, r);
    }
}

test "prepareSql: an empty statement is refused" {
    try testing.expectError(error.EmptySql, prepared(""));
    try testing.expectError(error.EmptySql, prepared("  \n\t "));
    try testing.expectError(error.EmptySql, prepared(" ; "));
}

test "FOR UPDATE right after a literal is still found" {
    try testing.expectError(error.ForUpdate, prepared("select 'it''s' from t for update"));
    try testing.expectError(error.ForUpdate, prepared("select q'[it's]' from t for update"));
    try testing.expectError(error.ForUpdate, prepared("select \"c\" from t for update"));
}

test "FOR UPDATE is refused in every spelling" {
    for ([_][]const u8{
        "select * from t for update",
        "SELECT * FROM t FOR UPDATE NOWAIT",
        "select * from t for\n   update of x.y skip locked",
        "select * from t for /* lock them */ update",
        "select * from t for -- note\n update",
        "select a from (select * from t) for update",
        "select * from t where x = 'a' for update wait 5;",
    }) |sql| {
        try testing.expectError(error.ForUpdate, prepared(sql));
    }
}

test "FOR UPDATE inside literals, identifiers and comments is not a lock" {
    for ([_][]const u8{
        "select 'for update' from dual",
        "select 'it''s for update' from dual",
        "select \"for update\" from t",
        "select * from t -- for update\n where x = 1",
        "select /* for update */ 1 from dual",
        "select q'[for update]' from dual",
        "select nq'{for update}' from dual",
        "select q'!for update!' from dual",
        "select for_update, update_x from t",
        "select * from for_updates",
        "select a.for, a.update from t a",
        "select 'x' for_ from dual",
        // a quote INSIDE an alternatively quoted literal does not end it
        "select q'[it's for update]' from dual",
        "select q'(don't) for update (really)' from dual",
        // a doubled quote is an escaped quote, so this is one literal
        "select 'a'' for update ''b' from dual",
    }) |sql| {
        const r = try prepared(sql);
        testing.allocator.free(r);
    }
}

// ---------------------------------------------------------------------------
// The ODPI-C session
// ---------------------------------------------------------------------------

/// Environment lookup backed by the real process environment.
pub const ProcessEnv = struct {
    pub fn get(self: ProcessEnv, a: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
        _ = self;
        return compat.getEnvOwned(a, name);
    }
};

pub const Params = struct {
    dsn: []const u8,
    creds: CredentialParams = .{},
    connect_secs: u32 = timeouts.default_connect_secs,
    call_secs: u32 = timeouts.default_call_secs,
};

pub const ColumnInfo = struct {
    name: []u8,
    type_info: c.dpiDataTypeInfo,
};

/// Result of describing a query without running it.
pub const Description = struct {
    /// the statement as it will be executed (see prepareSql)
    sql: []u8,
    columns: []ColumnInfo,

    pub fn deinit(self: *Description, a: std.mem.Allocator) void {
        a.free(self.sql);
        for (self.columns) |col| a.free(col.name);
        a.free(self.columns);
        self.* = .{ .sql = &.{}, .columns = &.{} };
    }
};

pub const Session = struct {
    ctx: *c.dpiContext,
    conn: *c.dpiConn,

    fn len32(s: []const u8) u32 {
        return @intCast(@min(s.len, std.math.maxInt(u32)));
    }

    /// The shared ODPI-C context; the first call in a process loads the Oracle client.
    fn context(msg: *Msg) ?*c.dpiContext {
        return oracle.getContext(msg) orelse {
            const tmp = msg.*;
            var hb: [768]u8 = undefined;
            const h = oracle.archHint(&hb, false);
            if (h.len > 0)
                msg.set("duckdb_oracle: Oracle client library could not be loaded: {s} | hint: {s}", .{ tmp.slice(), h })
            else
                msg.set("duckdb_oracle: Oracle client library could not be loaded: {s}", .{tmp.slice()});
            return null;
        };
    }

    /// Resolve credentials, load the client, connect and apply the call timeout.
    /// Failures set `msg` and return error.Bind; nothing is left open.
    pub fn open(a: std.mem.Allocator, p: Params, msg: *Msg) Error!Session {
        var creds = try resolveCredentials(a, ProcessEnv{}, p.creds, msg);
        defer creds.deinit(a); // zeroes the password

        const ctx = context(msg) orelse return error.Bind;

        var common = std.mem.zeroes(c.dpiCommonCreateParams);
        if (c.dpiContext_initCommonCreateParams(ctx, &common) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, ctx, "init connection parameters");
            return error.Bind;
        }
        common.createMode = c.DPI_MODE_CREATE_THREADED;
        common.encoding = "UTF-8";
        common.nencoding = "UTF-8";

        var conn_params = std.mem.zeroes(c.dpiConnCreateParams);
        const external = p.creds.auth == .external;
        if (external) {
            if (c.dpiContext_initConnCreateParams(ctx, &conn_params) != c.DPI_SUCCESS) {
                oracle.setDpiError(msg, ctx, "init connection parameters");
                return error.Bind;
            }
            conn_params.externalAuth = 1;
        }

        const connect_dsn = try timeouts.withConnectTimeout(a, p.dsn, p.connect_secs);
        defer a.free(connect_dsn);

        const user: []const u8 = if (creds.user) |u| u else "";
        const password: []const u8 = if (creds.password) |pw| pw else "";
        var conn: ?*c.dpiConn = null;
        if (c.dpiConn_create(
            ctx,
            if (external) null else user.ptr,
            if (external) 0 else len32(user),
            if (external) null else password.ptr,
            if (external) 0 else len32(password),
            connect_dsn.ptr,
            len32(connect_dsn),
            &common,
            if (external) &conn_params else null,
            &conn,
        ) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, ctx, "connect failed");
            return error.Bind;
        }
        const session: Session = .{ .ctx = ctx, .conn = conn.? };

        // Bounds every later round trip on this session (describe, execute, each fetch).
        if (p.call_secs > 0 and c.dpiConn_setCallTimeout(conn, timeouts.callTimeoutMs(p.call_secs)) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, ctx, "set call timeout");
            session.close();
            return error.Bind;
        }
        return session;
    }

    pub fn close(self: Session) void {
        _ = c.dpiConn_release(self.conn);
    }

    /// Check that `sql` (already through `prepareSql`) is a plain query and describe
    /// its columns without running it.
    pub fn describe(self: Session, a: std.mem.Allocator, sql_prepared: []const u8, msg: *Msg) Error!Description {
        const sql = try a.dupe(u8, sql_prepared);
        errdefer a.free(sql);

        var stmt: ?*c.dpiStmt = null;
        if (c.dpiConn_prepareStmt(self.conn, 0, sql.ptr, len32(sql), null, 0, &stmt) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, self.ctx, "prepare failed");
            return error.Bind;
        }
        defer _ = c.dpiStmt_release(stmt);

        var sinfo = std.mem.zeroes(c.dpiStmtInfo);
        if (c.dpiStmt_getInfo(stmt, &sinfo) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, self.ctx, "statement info");
            return error.Bind;
        }
        // Never run DDL/DML/PL/SQL: OCI executes DDL even in describe-only mode.
        if (sinfo.isQuery == 0) {
            msg.set("duckdb_oracle: oracle_query only runs queries (SELECT / WITH); writes, DDL and PL/SQL are not supported", .{});
            return error.Bind;
        }

        var ncols: u32 = 0;
        if (c.dpiStmt_execute(stmt, c.DPI_MODE_EXEC_DESCRIBE_ONLY, &ncols) != c.DPI_SUCCESS) {
            oracle.setDpiError(msg, self.ctx, "describe failed");
            return error.Bind;
        }
        if (ncols == 0) {
            msg.set("duckdb_oracle: oracle_query: the query returns no columns", .{});
            return error.Bind;
        }

        const cols = try a.alloc(ColumnInfo, ncols);
        var filled: usize = 0;
        errdefer {
            for (cols[0..filled]) |col| a.free(col.name);
            a.free(cols);
        }
        while (filled < ncols) {
            var qi = std.mem.zeroes(c.dpiQueryInfo);
            if (c.dpiStmt_getQueryInfo(stmt, @intCast(filled + 1), &qi) != c.DPI_SUCCESS) {
                oracle.setDpiError(msg, self.ctx, "describe column");
                return error.Bind;
            }
            const name: []const u8 = if (qi.name) |n| n[0..qi.nameLength] else "";
            cols[filled] = .{ .name = try a.dupe(u8, name), .type_info = qi.typeInfo };
            filled += 1;
        }
        return .{ .sql = sql, .columns = cols };
    }
};
