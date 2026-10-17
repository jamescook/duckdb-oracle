//! SQL text generation: everything duckdb-oracle writes into SQL that the user did not write.
//!
//! Pure functions, no Oracle and no DuckDB calls, so every string they produce is checked by unit
//! tests. Nothing here is ever given a chance to be injected into: user-supplied names go through
//! `appendQuoted` (an Oracle quoted identifier cannot contain a double quote, so quoting is complete)
//! or `appendLiteral` (quotes doubled).
//!
//! Contents
//!   * identifier quoting
//!   * the SDO_GEOMETRY wrapper (`wrapGeometry`)
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

