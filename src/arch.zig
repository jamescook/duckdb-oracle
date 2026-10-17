//! Process / host architecture helpers and the Windows-on-ARM guidance that
//! oracle_client_info() and oracle_query() add to "client not found" errors.
//!
//! Background: Oracle publishes Instant Client for Windows only as x64 and
//! x86 (32-bit); there is no Windows ARM64 build. A native ARM64 process
//! cannot load an x64 DLL, so the windows_arm64 extension can LOAD but can
//! never reach Oracle. On a Windows ARM64 machine the working combination is
//! the x64 DuckDB CLI + windows_amd64 extension + x64 Instant Client, all
//! running under Windows' x64 emulation.
const std = @import("std");
const builtin = @import("builtin");

/// Architecture of this process (= of the extension binary).
pub const process_arch: []const u8 = switch (builtin.cpu.arch) {
    .x86_64 => "x64",
    .aarch64 => "arm64",
    .x86 => "x86",
    else => @tagName(builtin.cpu.arch),
};

pub const Os = enum { windows, other };
pub const this_os: Os = if (builtin.os.tag == .windows) .windows else .other;

pub const arm64_no_client =
    "Windows ARM64: Oracle publishes no Windows ARM64 Instant Client, and a native ARM64 process cannot load an x64 oci.dll. " ++
    "Use the x64 DuckDB CLI + the windows_amd64 duckdb_oracle extension + the x64 Instant Client instead (they run under Windows x64 emulation).";

pub const emulated_no_client =
    "This x64 DuckDB is running under emulation on a Windows ARM64 host: install the x64 Instant Client (and the x64 Visual C++ redistributable) and put it first on PATH, or set DUCKDB_ORACLE_CLIENT_LIB_DIR.";

/// Guidance appended to a failed client load, or to the "OK" message.
/// `oci_arch` is the architecture of the first oci.dll on the search path, if any.
/// Returns an empty slice when there is nothing useful to add.
pub fn hint(buf: []u8, os: Os, process: []const u8, host: []const u8, oci_arch: ?[]const u8, client_found: bool) []const u8 {
    if (os != .windows) return "";
    if (client_found) {
        if (!std.mem.eql(u8, process, host) and host.len > 0)
            return std.fmt.bufPrint(buf, "{s} process running under emulation on an {s} host", .{ process, host }) catch "";
        return "";
    }
    var w: std.ArrayList(u8) = .initBuffer(buf);
    if (std.mem.eql(u8, process, "arm64")) {
        w.appendSliceBounded(arm64_no_client) catch return buf[0..w.items.len];
    } else if (std.mem.eql(u8, host, "arm64")) {
        w.appendSliceBounded(emulated_no_client) catch return buf[0..w.items.len];
    }
    if (oci_arch) |a| {
        if (!std.mem.eql(u8, a, process)) {
            if (w.items.len > 0) w.appendSliceBounded(" ") catch return w.items;
            w.printBounded("The first oci.dll on the search path is {s}, but this DuckDB process is {s}: the architectures must match.", .{ a, process }) catch return w.items;
        }
    }
    return w.items;
}

test "no hints off Windows" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings("", hint(&b, .other, "arm64", "arm64", null, false));
}

test "native ARM64 process without client" {
    var b: [1024]u8 = undefined;
    const h = hint(&b, .windows, "arm64", "arm64", null, false);
    try std.testing.expect(std.mem.indexOf(u8, h, "no Windows ARM64 Instant Client") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "windows_amd64") != null);
}

test "native ARM64 process with x64 oci.dll on PATH" {
    var b: [1024]u8 = undefined;
    const h = hint(&b, .windows, "arm64", "arm64", "x64", false);
    try std.testing.expect(std.mem.indexOf(u8, h, "first oci.dll on the search path is x64, but this DuckDB process is arm64") != null);
}

test "x64 process emulated on ARM64 host" {
    var b: [1024]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, hint(&b, .windows, "x64", "arm64", null, false), "under emulation") != null);
    try std.testing.expectEqualStrings("x64 process running under emulation on an arm64 host", hint(&b, .windows, "x64", "arm64", "x64", true));
}

test "x64 host, 32-bit oci.dll first" {
    var b: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "The first oci.dll on the search path is x86, but this DuckDB process is x64: the architectures must match.",
        hint(&b, .windows, "x64", "x64", "x86", false),
    );
    try std.testing.expectEqualStrings("", hint(&b, .windows, "x64", "x64", "x64", true));
}

test "small buffer never overflows" {
    var b: [16]u8 = undefined;
    const h = hint(&b, .windows, "arm64", "arm64", "x64", false);
    try std.testing.expect(h.len <= 16);
}
