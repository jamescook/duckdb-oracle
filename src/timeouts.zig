//! Connect and call timeout policy (pure; no OCI or DuckDB calls).
//!
//! Without these an unreachable or silent Oracle server hangs the whole DuckDB
//! session indefinitely, and Ctrl+C cannot help: the C Extension API gives a
//! table function no way to observe an interrupt while it is blocked in OCI.
const std = @import("std");

pub const default_connect_secs: u32 = 30;
pub const default_call_secs: u32 = 600;
/// dpiConn_setCallTimeout takes milliseconds in a u32.
pub const max_call_secs: u32 = std.math.maxInt(u32) / 1000;

/// Returns an owned copy of `dsn` with `connect_timeout=<secs>` added when that
/// is possible and not already specified. `connect_timeout` bounds the whole
/// connection handshake (a server that accepts the TCP connection and then
/// never answers is the case that hangs); `transport_connect_timeout` alone
/// does not. Only Easy Connect strings can be extended: TNS aliases and
/// descriptors (`(DESCRIPTION=...)`) are returned unchanged.
pub fn withConnectTimeout(a: std.mem.Allocator, dsn: []const u8, secs: u32) std.mem.Allocator.Error![]u8 {
    if (secs == 0 or !isEasyConnect(dsn) or containsIgnoreCase(dsn, "connect_timeout"))
        return a.dupe(u8, dsn);
    const sep: u8 = if (std.mem.indexOfScalar(u8, dsn, '?') != null) '&' else '?';
    return std.fmt.allocPrint(a, "{s}{c}connect_timeout={d}", .{ dsn, sep, secs });
}

/// host[:port][/service] or //host..., as opposed to a TNS alias or descriptor.
fn isEasyConnect(dsn: []const u8) bool {
    if (std.mem.indexOfScalar(u8, dsn, '(') != null) return false;
    return std.mem.indexOfAny(u8, dsn, ":/") != null;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

pub fn callTimeoutMs(secs: u32) u32 {
    const capped: u32 = @min(secs, max_call_secs); // explicit u32: @min of a comptime bound narrows the type
    return capped * 1000;
}

/// Extra guidance for timeout errors, or null when the message is unrelated.
pub fn hintFor(message: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, message, "DPI-1067") != null)
        return "the call timeout was reached; raise it with timeout := <seconds> (0 = no limit)";
    if (std.mem.indexOf(u8, message, "ORA-12170") != null)
        return "the connect timeout was reached; raise it with connect_timeout := <seconds> (0 = no limit)";
    return null;
}

const testing = std.testing;

fn decorated(dsn: []const u8, secs: u32) ![]u8 {
    return withConnectTimeout(testing.allocator, dsn, secs);
}

test "Easy Connect string gets connect_timeout" {
    const r = try decorated("db.example.com:1521/ORCLPDB1", 30);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("db.example.com:1521/ORCLPDB1?connect_timeout=30", r);
}

test "existing query parameters are extended with &" {
    const r = try decorated("//host/svc?retry_count=3", 5);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("//host/svc?retry_count=3&connect_timeout=5", r);
}

test "a DSN that already sets connect_timeout is left alone (any case)" {
    for ([_][]const u8{ "h:1/s?connect_timeout=2", "h:1/s?CONNECT_TIMEOUT=2&x=1", "h:1/s?retry_count=1&Connect_Timeout=9" }) |dsn| {
        const r = try decorated(dsn, 30);
        defer testing.allocator.free(r);
        try testing.expectEqualStrings(dsn, r);
    }
}

test "TNS aliases and full descriptors cannot be extended" {
    for ([_][]const u8{ "ORCLPDB1", "localhost", "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=h)(PORT=1))(CONNECT_DATA=(SERVICE_NAME=s)))" }) |dsn| {
        const r = try decorated(dsn, 30);
        defer testing.allocator.free(r);
        try testing.expectEqualStrings(dsn, r);
    }
}

test "zero disables the connect timeout" {
    const r = try decorated("h:1/s", 0);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("h:1/s", r);
}

test "call timeout is converted to milliseconds and saturates" {
    try testing.expectEqual(@as(u32, 0), callTimeoutMs(0));
    try testing.expectEqual(@as(u32, 600_000), callTimeoutMs(600));
    try testing.expectEqual(@as(u32, 4_294_967_000), callTimeoutMs(max_call_secs));
    try testing.expectEqual(@as(u32, 4_294_967_000), callTimeoutMs(std.math.maxInt(u32)));
}

test "timeout errors get a hint, others do not" {
    const h1 = hintFor("DPI-1067: call timeout of 600000 ms exceeded with ORA-03156").?;
    try testing.expect(std.mem.indexOf(u8, h1, "timeout :=") != null);
    const h2 = hintFor("ORA-12170: Cannot connect. Outbound connect timeout of 30s for host h port 1").?;
    try testing.expect(std.mem.indexOf(u8, h2, "connect_timeout :=") != null);
    try testing.expect(hintFor("ORA-01017: invalid credential or not authorized") == null);
}
