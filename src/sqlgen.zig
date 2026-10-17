//! SQL text generation: everything duckdb-oracle writes into SQL that the user did not write.
//!
//! Pure functions, no Oracle and no DuckDB calls, so every string they produce is checked by unit
//! tests. Nothing here is ever given a chance to be injected into: user-supplied names go through
//! `appendQuoted` (an Oracle quoted identifier cannot contain a double quote, so quoting is complete)
//! or `appendLiteral` (quotes doubled).
//!
//! Contents
//!   * identifier quoting and Oracle name parsing (`parseName`)
//!   * the SDO_GEOMETRY wrapper (`wrapGeometry`)
//!   * the catalog queries behind oracle_scan and oracle_tables
//!   * `ALTER SESSION SET CURRENT_SCHEMA`
const std = @import("std");

pub const max_identifier_bytes = 128;

const List = std.ArrayList(u8);

// ---------------------------------------------------------------------------
// Identifiers and literals
// ---------------------------------------------------------------------------

/// True when `name` can be written as an Oracle quoted identifier: 1 to 128 bytes, no double quote
/// and no NUL. (Oracle labels an unaliased expression with its own text, which can contain quotes:
/// such a column cannot be referenced by name at all.)
pub fn isQuotable(name: []const u8) bool {
    if (name.len == 0 or name.len > max_identifier_bytes) return false;
    for (name) |ch| if (ch == '"' or ch == 0) return false;
    return true;
}

/// Appends `"name"`; refuses a name that cannot be an Oracle quoted identifier, so a hostile or odd
/// name can never close the quotes.
fn appendQuoted(a: std.mem.Allocator, out: *List, name: []const u8) !void {
    if (!isQuotable(name)) return error.Unquotable;
    try out.append(a, '"');
    try out.appendSlice(a, name);
    try out.append(a, '"');
}

/// Appends a SQL string literal: 'text' with every quote doubled.
fn appendLiteral(a: std.mem.Allocator, out: *List, text: []const u8) !void {
    try out.append(a, '\'');
    for (text) |ch| {
        if (ch == '\'') try out.append(a, '\'');
        try out.append(a, ch);
    }
    try out.append(a, '\'');
}

// ---------------------------------------------------------------------------
// Oracle names: [schema.]object, quoted or not
// ---------------------------------------------------------------------------

pub const NameError = error{ Empty, TooManyParts, DbLink, BadQuote, BadChar, TooLong, OutOfMemory };

pub fn describeNameError(e: NameError) []const u8 {
    return switch (e) {
        error.Empty => "the name is empty",
        error.TooManyParts => "at most two parts (schema.object) are supported",
        error.DbLink => "database links (name@link) are not supported; use oracle_query with the link written in the SQL",
        error.BadQuote => "a quoted identifier must be \"text\" with no double quote inside it and must not be empty",
        error.BadChar => "unexpected character; an unquoted name has letters, digits, _, $ and #, and starts with a letter; quote anything else with double quotes",
        error.TooLong => "an Oracle identifier has at most 128 bytes",
        error.OutOfMemory => "out of memory",
    };
}

/// A one- or two-part Oracle name as Oracle itself reads it: an unquoted part is folded to upper
/// case (ASCII only: quote a name that contains other letters), a quoted part is taken exactly.
pub const Name = struct {
    /// owned; `parts[0]` is the schema when `count == 2`
    parts: [2][]u8 = .{ &.{}, &.{} },
    count: usize = 0,

    pub fn deinit(self: *Name, a: std.mem.Allocator) void {
        for (self.parts[0..self.count]) |p| a.free(p);
        self.* = .{};
    }

    pub fn schema(self: *const Name) ?[]const u8 {
        return if (self.count == 2) self.parts[0] else null;
    }

    pub fn object(self: *const Name) []const u8 {
        return self.parts[self.count - 1];
    }
};

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch >= 0x80;
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$' or ch == '#' or ch >= 0x80;
}

pub fn parseName(a: std.mem.Allocator, text: []const u8) NameError!Name {
    var name: Name = .{};
    errdefer name.deinit(a);
    var i: usize = 0;
    while (true) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) return error.Empty;
        var part: []u8 = undefined;
        if (text[i] == '"') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse return error.BadQuote;
            if (close == i + 1) return error.BadQuote; // ""
            if (close + 1 < text.len and text[close + 1] == '"') return error.BadQuote; // "" inside: Oracle has no escape
            if (std.mem.indexOfScalar(u8, text[i + 1 .. close], 0) != null) return error.BadQuote;
            part = try a.dupe(u8, text[i + 1 .. close]);
            i = close + 1;
        } else {
            if (text[i] == '@') return error.DbLink;
            if (!isIdentStart(text[i])) return error.BadChar;
            const start = i;
            while (i < text.len and isIdentChar(text[i])) i += 1;
            part = try a.dupe(u8, text[start..i]);
            for (part) |*ch| ch.* = std.ascii.toUpper(ch.*);
        }
        if (part.len > max_identifier_bytes) {
            a.free(part);
            return error.TooLong;
        }
        if (name.count == 2) {
            a.free(part);
            return error.TooManyParts;
        }
        name.parts[name.count] = part;
        name.count += 1;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) return name;
        switch (text[i]) {
            '.' => {
                i += 1;
                if (name.count == 2) return error.TooManyParts;
            },
            '@' => return error.DbLink,
            else => return error.BadChar,
        }
    }
}

// ---------------------------------------------------------------------------
// SDO_GEOMETRY
// ---------------------------------------------------------------------------

pub const geometry_schema = "MDSYS";
pub const geometry_type = "SDO_GEOMETRY";

/// True for the Oracle Spatial / Locator geometry object type MDSYS.SDO_GEOMETRY.
pub fn isSdoGeometry(schema: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, schema, geometry_schema) and std.mem.eql(u8, name, geometry_type);
}

/// What geometry columns become (the `geometry :=` option).
pub const GeometryMode = enum {
    /// Well-known binary, as BLOB (SDO_UTIL.TO_WKBGEOMETRY); DuckDB reads it with ST_GeomFromWKB
    wkb,
    /// Well-known text, as VARCHAR (SDO_UTIL.TO_WKTGEOMETRY)
    wkt,

    pub fn parse(text: []const u8) ?GeometryMode {
        // an explicit table: @typeInfo's enum layout differs between Zig 0.15 and 0.17
        const names = [_]struct { []const u8, GeometryMode }{ .{ "wkb", .wkb }, .{ "wkt", .wkt } };
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(text, n[0])) return n[1];
        }
        return null;
    }

    pub fn function(self: GeometryMode) []const u8 {
        return switch (self) {
            .wkb => "MDSYS.SDO_UTIL.TO_WKBGEOMETRY",
            .wkt => "MDSYS.SDO_UTIL.TO_WKTGEOMETRY",
        };
    }
};

/// What a column of the wrapped query must look like once Oracle has described it again.
pub const Expect = enum { passthrough, wkb, wkt, srid };

pub const Wrapped = struct {
    /// the statement to run instead of the user's
    sql: []u8,
    /// per output column of the wrapped statement
    expect: []Expect,
    /// DuckDB column names, same length as `expect`: the user's names, plus `<name>_srid`
    names: [][]u8,

    pub fn deinit(self: *Wrapped, a: std.mem.Allocator) void {
        a.free(self.sql);
        a.free(self.expect);
        for (self.names) |n| a.free(n);
        a.free(self.names);
        self.* = undefined;
    }
};

/// True when every name can be written as a quoted identifier and no two are equal: then the
/// user's query can be wrapped as an inline view and its columns referenced by name.
fn namesReferencable(names: []const []const u8) bool {
    for (names, 0..) |n, i| {
        if (!isQuotable(n)) return false;
        for (names[0..i]) |m| if (std.mem.eql(u8, n, m)) return false;
    }
    return true;
}

pub const alias_cte = "DUCKDB_ORACLE_Q";

/// Wrap the user's query so that each SDO_GEOMETRY column comes back as WKB or WKT (no object
/// type reaches ODPI-C) and, with `with_srid`, followed by an extra `<name>_srid` column.
///
///   unique, quotable names (the usual case):
///     SELECT q."ID", MDSYS.SDO_UTIL.TO_WKBGEOMETRY(q."GEOM") FROM (<sql>) q
///   duplicate, empty or unquotable names (a column cannot be referenced by name, so the columns
///   are renamed positionally with a WITH column list, which Oracle has supported since 11.2):
///     WITH "DUCKDB_ORACLE_Q" ("C1", "C2") AS (<sql>) SELECT "C1", ...TO_WKBGEOMETRY("DUCKDB_ORACLE_Q"."C2") FROM "DUCKDB_ORACLE_Q"
///
/// The user's text goes on its own lines so that a trailing `-- comment` cannot swallow the
/// closing parenthesis.
pub fn wrapGeometry(
    a: std.mem.Allocator,
    user_sql: []const u8,
    names: []const []const u8,
    is_geometry: []const bool,
    mode: GeometryMode,
    with_srid: bool,
) !Wrapped {
    std.debug.assert(names.len == is_geometry.len);
    const by_name = namesReferencable(names);

    var sql: List = .empty;
    errdefer sql.deinit(a);
    var expect: std.ArrayList(Expect) = .empty;
    errdefer expect.deinit(a);
    var out_names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out_names.items) |n| a.free(n);
        out_names.deinit(a);
    }

    if (!by_name) {
        try sql.appendSlice(a, "WITH ");
        try appendQuoted(a, &sql, alias_cte);
        try sql.appendSlice(a, " (");
        for (names, 0..) |_, i| {
            if (i > 0) try sql.appendSlice(a, ", ");
            try sql.print(a, "\"C{d}\"", .{i + 1});
        }
        try sql.appendSlice(a, ") AS (\n");
        try sql.appendSlice(a, user_sql);
        try sql.appendSlice(a, "\n)\nSELECT ");
    } else {
        try sql.appendSlice(a, "SELECT ");
    }

    for (names, is_geometry, 0..) |name, geom, i| {
        // how this column is referenced from the outer query
        var ref: List = .empty;
        defer ref.deinit(a);
        if (by_name) {
            try ref.appendSlice(a, "q.");
            try appendQuoted(a, &ref, name);
        } else {
            try appendQuoted(a, &ref, alias_cte);
            try ref.print(a, ".\"C{d}\"", .{i + 1});
        }
        if (i > 0) try sql.appendSlice(a, ", ");
        if (geom) {
            try sql.print(a, "{s}({s})", .{ mode.function(), ref.items });
            try expect.append(a, if (mode == .wkb) .wkb else .wkt);
            try out_names.append(a, try a.dupe(u8, name));
            if (with_srid) {
                try sql.print(a, ", CAST({s}.SDO_SRID AS NUMBER(10))", .{ref.items});
                try expect.append(a, .srid);
                try out_names.append(a, try std.fmt.allocPrint(a, "{s}_srid", .{name}));
            }
        } else {
            try sql.appendSlice(a, ref.items);
            try expect.append(a, .passthrough);
            try out_names.append(a, try a.dupe(u8, name));
        }
    }

    if (by_name) {
        try sql.appendSlice(a, " FROM (\n");
        try sql.appendSlice(a, user_sql);
        try sql.appendSlice(a, "\n) q");
    } else {
        try sql.append(a, ' ');
        try sql.appendSlice(a, "FROM ");
        try appendQuoted(a, &sql, alias_cte);
    }

    return .{
        .sql = try sql.toOwnedSlice(a),
        .expect = try expect.toOwnedSlice(a),
        .names = try out_names.toOwnedSlice(a),
    };
}

// ---------------------------------------------------------------------------
// Catalog queries: oracle_scan, oracle_tables, current_schema
// ---------------------------------------------------------------------------

const scannable_types = "('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'SYNONYM')";
const current_schema_expr = "SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')";

/// `SELECT SYS_CONTEXT(...) FROM dual`: the schema unqualified names resolve in.
pub const current_schema_query = "SELECT " ++ current_schema_expr ++ " FROM dual";

/// The query that finds what a name refers to, one row per candidate (owner, object name, object
/// type), best candidate first. An unqualified name is a private object (table, view, materialized
/// view or private synonym) of the current schema, otherwise a public synonym: the order Oracle uses.
/// A qualified name is exactly that schema's object.
pub fn resolveQuery(a: std.mem.Allocator, name: *const Name) ![]u8 {
    var q: List = .empty;
    errdefer q.deinit(a);
    if (name.schema()) |schema| {
        try q.appendSlice(a, "SELECT owner, object_name, object_type FROM all_objects WHERE owner = ");
        try appendLiteral(a, &q, schema);
        try q.appendSlice(a, " AND object_name = ");
        try appendLiteral(a, &q, name.object());
        try q.appendSlice(a, " AND object_type IN " ++ scannable_types);
    } else {
        try q.appendSlice(a, "SELECT owner, object_name, object_type FROM (" ++
            "SELECT owner, object_name, object_type, 1 AS pri FROM all_objects WHERE owner = " ++ current_schema_expr ++ " AND object_name = ");
        try appendLiteral(a, &q, name.object());
        try q.appendSlice(a, " AND object_type IN " ++ scannable_types ++
            " UNION ALL " ++
            "SELECT owner, object_name, object_type, 2 AS pri FROM all_objects WHERE owner = 'PUBLIC' AND object_name = ");
        try appendLiteral(a, &q, name.object());
        try q.appendSlice(a, " AND object_type = 'SYNONYM') ORDER BY pri");
    }
    return q.toOwnedSlice(a);
}

/// The SELECT that reads what `resolveQuery` found. A private object (or a qualified name) is
/// referenced as "OWNER"."NAME"; a public synonym is referenced by its bare name, which Oracle
/// resolves to the synonym because the current schema has no object of that name.
pub fn scanSql(a: std.mem.Allocator, owner: []const u8, object: []const u8, object_type: []const u8) ![]u8 {
    var q: List = .empty;
    errdefer q.deinit(a);
    try q.appendSlice(a, "SELECT * FROM ");
    if (!std.mem.eql(u8, owner, "PUBLIC")) {
        try appendQuoted(a, &q, owner);
        try q.append(a, '.');
    } else std.debug.assert(std.mem.eql(u8, object_type, "SYNONYM"));
    try appendQuoted(a, &q, object);
    return q.toOwnedSlice(a);
}

/// Human text for the "nothing found" error: what was tried, in order.
pub fn triedDescription(a: std.mem.Allocator, name: *const Name, current_schema: []const u8) ![]u8 {
    if (name.schema()) |schema| {
        return std.fmt.allocPrint(a, "the table, view, materialized view or synonym \"{s}\".\"{s}\"", .{ schema, name.object() });
    }
    return std.fmt.allocPrint(
        a,
        "(1) \"{s}\".\"{s}\" - a table, view, materialized view or private synonym in the current schema; (2) a public synonym \"{s}\"",
        .{ current_schema, name.object(), name.object() },
    );
}

/// The whole "nothing found" error of oracle_scan. `current_schema` is only used for a bare name.
pub fn scanNotFoundMessage(a: std.mem.Allocator, raw_name: []const u8, name: *const Name, current_schema: []const u8) ![]u8 {
    const tried = try triedDescription(a, name, current_schema);
    defer a.free(tried);
    return std.fmt.allocPrint(
        a,
        "duckdb_oracle: oracle_scan: nothing named '{s}' is visible to this user. Tried: {s}. " ++
            "Unquoted names are folded to upper case; quote a case-sensitive name (e.g. '\"MixedCase\"'). " ++
            "oracle_tables(dsn) lists what is visible; current_schema := 'X' changes where bare names resolve",
        .{ raw_name, tried },
    );
}

/// oracle_tables: tables, views, materialized views and synonyms of one schema (the session's
/// current schema when `schema` is null), with a synonym's target. Recycle-bin objects (BIN$...) are left out.
pub fn tablesQuery(a: std.mem.Allocator, schema: ?[]const u8) ![]u8 {
    var q: List = .empty;
    errdefer q.deinit(a);
    try q.appendSlice(a,
        "SELECT o.owner AS owner, o.object_name AS name, o.object_type AS type, " ++
            "CASE WHEN o.object_type = 'SYNONYM' THEN s.table_owner || '.' || s.table_name || " ++
            "CASE WHEN s.db_link IS NOT NULL THEN '@' || s.db_link END END AS synonym_target " ++
            "FROM all_objects o LEFT JOIN all_synonyms s " ++
            "ON o.object_type = 'SYNONYM' AND s.owner = o.owner AND s.synonym_name = o.object_name " ++
            "WHERE o.object_type IN " ++ scannable_types ++ " AND o.object_name NOT LIKE 'BIN$%' AND o.owner = ");
    if (schema) |s| try appendLiteral(a, &q, s) else try q.appendSlice(a, current_schema_expr);
    try q.appendSlice(a, " ORDER BY o.owner, o.object_name");
    return q.toOwnedSlice(a);
}

/// `ALTER SESSION SET CURRENT_SCHEMA = "X"`; `schema` is the already-parsed (folded) name.
pub fn alterSchemaSql(a: std.mem.Allocator, schema: []const u8) ![]u8 {
    var q: List = .empty;
    errdefer q.deinit(a);
    try q.appendSlice(a, "ALTER SESSION SET CURRENT_SCHEMA = ");
    try appendQuoted(a, &q, schema);
    return q.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

/// `ch` repeated `n` times (Zig 0.17 has no `**` array repeat).
fn repeat(comptime ch: u8, comptime n: usize) [n]u8 {
    return @splat(ch);
}

const x128 = repeat('x', 128);
const x129 = repeat('x', 129);
const n129 = repeat('n', 129);
const quoted_y200 = quoted_y200;

fn parsed(text: []const u8) !Name {
    return parseName(testing.allocator, text);
}

test "isQuotable: what Oracle allows between double quotes" {
    try testing.expect(isQuotable("A"));
    try testing.expect(isQuotable("Mixed Case $#"));
    try testing.expect(isQuotable("h\xc3\xa9llo"));
    try testing.expect(isQuotable(&x128));
    try testing.expect(!isQuotable(""));
    try testing.expect(!isQuotable(&x129));
    try testing.expect(!isQuotable("a\"b"));
    try testing.expect(!isQuotable("a\x00b"));
}

test "appendQuoted refuses a name that could close the quotes" {
    var out: List = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.Unquotable, appendQuoted(testing.allocator, &out, "a\"; drop table t; --"));
    try testing.expectError(error.Unquotable, appendQuoted(testing.allocator, &out, ""));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "appendLiteral doubles quotes" {
    var out: List = .empty;
    defer out.deinit(testing.allocator);
    try appendLiteral(testing.allocator, &out, "it's ''x''");
    try testing.expectEqualStrings("'it''s ''''x'''''", out.items);
}

test "parseName: unquoted parts fold to upper case, quoted parts are exact" {
    var n = try parsed("orders");
    defer n.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), n.count);
    try testing.expectEqualStrings("ORDERS", n.object());
    try testing.expect(n.schema() == null);

    var m = try parsed("  hr.Orders_2$# ");
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("HR", m.schema().?);
    try testing.expectEqualStrings("ORDERS_2$#", m.object());

    var q = try parsed("\"MixedCase\"");
    defer q.deinit(testing.allocator);
    try testing.expectEqualStrings("MixedCase", q.object());

    var qq = try parsed("sales.\"Q1 results\"");
    defer qq.deinit(testing.allocator);
    try testing.expectEqualStrings("SALES", qq.schema().?);
    try testing.expectEqualStrings("Q1 results", qq.object());

    var both = try parsed("\"hr\" . \"t\"");
    defer both.deinit(testing.allocator);
    try testing.expectEqualStrings("hr", both.schema().?);
    try testing.expectEqualStrings("t", both.object());

    // a dot inside quotes is part of the name
    var dot = try parsed("\"a.b\"");
    defer dot.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), dot.count);
    try testing.expectEqualStrings("a.b", dot.object());
}

test "parseName: errors say what is wrong" {
    try testing.expectError(error.Empty, parsed(""));
    try testing.expectError(error.Empty, parsed("   "));
    try testing.expectError(error.Empty, parsed("a."));
    try testing.expectError(error.TooManyParts, parsed("a.b.c"));
    try testing.expectError(error.DbLink, parsed("t@remote"));
    try testing.expectError(error.DbLink, parsed("a.t @ remote"));
    try testing.expectError(error.DbLink, parsed("@x"));
    try testing.expectError(error.BadQuote, parsed("\"\""));
    try testing.expectError(error.BadQuote, parsed("\"abc"));
    try testing.expectError(error.BadQuote, parsed("\"a\"\"b\""));
    try testing.expectError(error.BadQuote, parsed("\"a\x00b\""));
    try testing.expectError(error.BadChar, parsed("1abc"));
    try testing.expectError(error.BadChar, parsed("a b"));
    try testing.expectError(error.BadChar, parsed("a-b"));
    try testing.expectError(error.BadChar, parsed("a;drop table x"));
    try testing.expectError(error.TooLong, parsed(&x129));
    try testing.expect(describeNameError(error.DbLink).len > 0);
}

test "parseName never leaks on its error paths" {
    // testing.allocator reports leaks; run every failing input through it
    var long_quoted: [202]u8 = undefined;
    long_quoted[0] = '"';
    @memset(long_quoted[1..201], 'y');
    long_quoted[201] = '"';
    for ([_][]const u8{ "a.b.c", "x.\"", "\"a\".\"\"", "a.", &long_quoted }) |t| {
        try testing.expect(std.meta.isError(parsed(t)));
    }
}

test "GeometryMode.parse" {
    try testing.expectEqual(GeometryMode.wkb, GeometryMode.parse("WKB").?);
    try testing.expectEqual(GeometryMode.wkt, GeometryMode.parse("wkt").?);
    try testing.expect(GeometryMode.parse("geojson") == null);
}

test "isSdoGeometry is exact" {
    try testing.expect(isSdoGeometry("MDSYS", "SDO_GEOMETRY"));
    try testing.expect(!isSdoGeometry("MDSYS", "SDO_POINT_TYPE"));
    try testing.expect(!isSdoGeometry("SCOTT", "SDO_GEOMETRY"));
    try testing.expect(!isSdoGeometry("mdsys", "sdo_geometry"));
}

fn wrapped(sql: []const u8, names: []const []const u8, geom: []const bool, mode: GeometryMode, srid: bool) !Wrapped {
    return wrapGeometry(testing.allocator, sql, names, geom, mode, srid);
}

test "wrapGeometry: the usual case is an inline view with each name quoted" {
    var w = try wrapped("SELECT id, shape FROM parcels", &.{ "ID", "SHAPE" }, &.{ false, true }, .wkb, false);
    defer w.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "SELECT q.\"ID\", MDSYS.SDO_UTIL.TO_WKBGEOMETRY(q.\"SHAPE\") FROM (\nSELECT id, shape FROM parcels\n) q",
        w.sql,
    );
    try testing.expectEqualSlices(Expect, &.{ .passthrough, .wkb }, w.expect);
    try testing.expectEqualStrings("SHAPE", w.names[1]);
}

test "wrapGeometry: case-sensitive and odd names are quoted exactly" {
    var w = try wrapped("select 1 from dual", &.{ "Mixed Case", "geo$m#" }, &.{ false, true }, .wkt, false);
    defer w.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "SELECT q.\"Mixed Case\", MDSYS.SDO_UTIL.TO_WKTGEOMETRY(q.\"geo$m#\") FROM (\nselect 1 from dual\n) q",
        w.sql,
    );
    try testing.expectEqualSlices(Expect, &.{ .passthrough, .wkt }, w.expect);
}

test "wrapGeometry: a SRID column follows its geometry; several geometries; names" {
    var w = try wrapped("x", &.{ "A", "G1", "B", "G2" }, &.{ false, true, false, true }, .wkb, true);
    defer w.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "SELECT q.\"A\", MDSYS.SDO_UTIL.TO_WKBGEOMETRY(q.\"G1\"), CAST(q.\"G1\".SDO_SRID AS NUMBER(10)), q.\"B\", " ++
            "MDSYS.SDO_UTIL.TO_WKBGEOMETRY(q.\"G2\"), CAST(q.\"G2\".SDO_SRID AS NUMBER(10)) FROM (\nx\n) q",
        w.sql,
    );
    try testing.expectEqualSlices(Expect, &.{ .passthrough, .wkb, .srid, .passthrough, .wkb, .srid }, w.expect);
    try testing.expectEqual(@as(usize, 6), w.names.len);
    try testing.expectEqualStrings("G1_srid", w.names[2]);
    try testing.expectEqualStrings("G2_srid", w.names[5]);
}

test "wrapGeometry: duplicate names are renamed positionally with a WITH column list" {
    var w = try wrapped("SELECT a.id, b.id, a.g FROM a, b", &.{ "ID", "ID", "G" }, &.{ false, false, true }, .wkb, false);
    defer w.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "WITH \"DUCKDB_ORACLE_Q\" (\"C1\", \"C2\", \"C3\") AS (\nSELECT a.id, b.id, a.g FROM a, b\n)\n" ++
            "SELECT \"DUCKDB_ORACLE_Q\".\"C1\", \"DUCKDB_ORACLE_Q\".\"C2\", " ++
            "MDSYS.SDO_UTIL.TO_WKBGEOMETRY(\"DUCKDB_ORACLE_Q\".\"C3\") FROM \"DUCKDB_ORACLE_Q\"",
        w.sql,
    );
    // the DuckDB names are still the user's, duplicates included
    try testing.expectEqualStrings("ID", w.names[0]);
    try testing.expectEqualStrings("ID", w.names[1]);
}

test "wrapGeometry: a name with a double quote, an empty name or a too long name takes the positional form" {
    for ([_][]const u8{ "'A'||\"X\"", "", &n129 }) |odd| {
        var w = try wrapped("select 1 from dual", &.{ odd, "G" }, &.{ false, true }, .wkb, true);
        defer w.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, w.sql, "WITH \"DUCKDB_ORACLE_Q\" (\"C1\", \"C2\") AS ("));
        try testing.expect(std.mem.indexOf(u8, w.sql, "CAST(\"DUCKDB_ORACLE_Q\".\"C2\".SDO_SRID AS NUMBER(10))") != null);
        // the odd name never appears in the generated SQL
        if (odd.len > 0 and odd.len < 100) try testing.expect(std.mem.indexOf(u8, w.sql, odd) == null);
    }
}

test "wrapGeometry: a trailing line comment cannot swallow the closing parenthesis" {
    var w = try wrapped("select g from t -- note", &.{"G"}, &.{true}, .wkb, false);
    defer w.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, w.sql, "select g from t -- note\n) q"));
}

test "resolveQuery: unqualified names try the current schema, then public synonyms" {
    var n = try parsed("orders");
    defer n.deinit(testing.allocator);
    const q = try resolveQuery(testing.allocator, &n);
    defer testing.allocator.free(q);
    try testing.expectEqualStrings(
        "SELECT owner, object_name, object_type FROM (" ++
            "SELECT owner, object_name, object_type, 1 AS pri FROM all_objects WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') " ++
            "AND object_name = 'ORDERS' AND object_type IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'SYNONYM') " ++
            "UNION ALL " ++
            "SELECT owner, object_name, object_type, 2 AS pri FROM all_objects WHERE owner = 'PUBLIC' " ++
            "AND object_name = 'ORDERS' AND object_type = 'SYNONYM') ORDER BY pri",
        q,
    );
}

test "resolveQuery: a qualified name is exactly that schema's object; quotes in names are doubled" {
    var n = try parsed("\"o'brien\".\"T\"");
    defer n.deinit(testing.allocator);
    const q = try resolveQuery(testing.allocator, &n);
    defer testing.allocator.free(q);
    try testing.expectEqualStrings(
        "SELECT owner, object_name, object_type FROM all_objects WHERE owner = 'o''brien' AND object_name = 'T' " ++
            "AND object_type IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'SYNONYM')",
        q,
    );
}

test "scanSql: private objects are qualified, a public synonym is referenced by its bare name" {
    const a = testing.allocator;
    const s1 = try scanSql(a, "HR", "Mixed Case", "TABLE");
    defer a.free(s1);
    try testing.expectEqualStrings("SELECT * FROM \"HR\".\"Mixed Case\"", s1);
    const s2 = try scanSql(a, "PUBLIC", "EMP_SYN", "SYNONYM");
    defer a.free(s2);
    try testing.expectEqualStrings("SELECT * FROM \"EMP_SYN\"", s2);
}

test "triedDescription lists both candidates for a bare name" {
    const a = testing.allocator;
    var n = try parsed("orders");
    defer n.deinit(a);
    const t = try triedDescription(a, &n, "HR");
    defer a.free(t);
    try testing.expectEqualStrings(
        "(1) \"HR\".\"ORDERS\" - a table, view, materialized view or private synonym in the current schema; (2) a public synonym \"ORDERS\"",
        t,
    );
    var q = try parsed("sales.t");
    defer q.deinit(a);
    const t2 = try triedDescription(a, &q, "HR");
    defer a.free(t2);
    try testing.expectEqualStrings("the table, view, materialized view or synonym \"SALES\".\"T\"", t2);
}

test "tablesQuery: current schema by default, an explicit schema as a literal" {
    const a = testing.allocator;
    const q1 = try tablesQuery(a, null);
    defer a.free(q1);
    try testing.expect(std.mem.endsWith(u8, q1, "AND o.owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') ORDER BY o.owner, o.object_name"));
    try testing.expect(std.mem.indexOf(u8, q1, "AND o.object_name NOT LIKE 'BIN$%'") != null); // recycle bin
    try testing.expect(std.mem.indexOf(u8, q1, "LEFT JOIN all_synonyms s ON o.object_type = 'SYNONYM'") != null);
    const q2 = try tablesQuery(a, "O'NEIL");
    defer a.free(q2);
    try testing.expect(std.mem.endsWith(u8, q2, "AND o.owner = 'O''NEIL' ORDER BY o.owner, o.object_name"));
}

test "alterSchemaSql quotes the schema" {
    const a = testing.allocator;
    const s = try alterSchemaSql(a, "Hr Test");
    defer a.free(s);
    try testing.expectEqualStrings("ALTER SESSION SET CURRENT_SCHEMA = \"Hr Test\"", s);
}

test "scanNotFoundMessage: the full error for a bare name and for a qualified one" {
    const a = testing.allocator;
    var bare = try parsed("e2e_no_such_thing");
    defer bare.deinit(a);
    const m1 = try scanNotFoundMessage(a, "e2e_no_such_thing", &bare, "E2E_APP");
    defer a.free(m1);
    try testing.expectEqualStrings(
        "duckdb_oracle: oracle_scan: nothing named 'e2e_no_such_thing' is visible to this user. Tried: " ++
            "(1) \"E2E_APP\".\"E2E_NO_SUCH_THING\" - a table, view, materialized view or private synonym in the current schema; " ++
            "(2) a public synonym \"E2E_NO_SUCH_THING\". " ++
            "Unquoted names are folded to upper case; quote a case-sensitive name (e.g. '\"MixedCase\"'). " ++
            "oracle_tables(dsn) lists what is visible; current_schema := 'X' changes where bare names resolve",
        m1,
    );
    var q = try parsed("e2e_owner.mixedcase");
    defer q.deinit(a);
    const m2 = try scanNotFoundMessage(a, "e2e_owner.mixedcase", &q, "ignored");
    defer a.free(m2);
    try testing.expect(std.mem.indexOf(u8, m2, "nothing named 'e2e_owner.mixedcase' is visible") != null);
    try testing.expect(std.mem.indexOf(u8, m2, "Tried: the table, view, materialized view or synonym \"E2E_OWNER\".\"MIXEDCASE\".") != null);
    try testing.expect(m1.len < 2000 and m2.len < 2000); // fits the error buffer without truncation
}
