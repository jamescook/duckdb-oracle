//! Lazily initialised ODPI-C context and error helpers.
//!
//! The OCI library (oci.dll / libclntsh.so) is only loaded the first time an
//! Oracle function is actually executed, never from the extension entrypoint,
//! so `LOAD duckdb_oracle` works without Oracle Instant Client installed.
const std = @import("std");
const compat = @import("compat.zig");
const c = @import("c.zig").c;
const arch = @import("arch.zig");

var mutex: compat.Mutex = .{};
var context: ?*c.dpiContext = null;

pub const odpi_version = std.fmt.comptimePrint("{d}.{d}.{d}", .{ c.DPI_MAJOR_VERSION, c.DPI_MINOR_VERSION, c.DPI_PATCH_LEVEL });

/// Optional override for the directory containing oci.dll / libclntsh.so.
/// Useful on Windows hosts that also have a 32-bit client on PATH.
pub const lib_dir_env = "DUCKDB_ORACLE_CLIENT_LIB_DIR";

/// Fixed-size, NUL-terminated message buffer (no allocation on error paths).
pub const Msg = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Msg, comptime fmt: []const u8, args: anytype) void {
        const s = compat.bufPrintZ(&self.buf, fmt, args) catch blk: {
            // truncate long messages but keep them NUL-terminated
            self.buf[self.buf.len - 1] = 0;
            break :blk self.buf[0 .. self.buf.len - 1 :0];
        };
        self.len = s.len;
    }

    pub fn z(self: *const Msg) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }

    pub fn slice(self: *const Msg) []const u8 {
        return self.buf[0..self.len];
    }
};

fn trimMsg(ptr: ?[*]const u8, len: u32) []const u8 {
    const p = ptr orelse return "(no message)";
    return std.mem.trimEnd(u8, p[0..len], " \r\n\x00");
}

/// Returns the shared ODPI-C context, creating it (and loading OCI) on first
/// use. On failure `msg` receives the DPI-xxxx error text and null is returned.
/// A failed attempt is not cached: installing Instant Client and retrying in
/// the same session works.
pub fn getContext(msg: *Msg) ?*c.dpiContext {
    mutex.lock();
    defer mutex.unlock();
    if (context) |ctx| return ctx;

    var params = std.mem.zeroes(c.dpiContextCreateParams);
    params.defaultDriverName = "duckdb_oracle";
    params.defaultEncoding = "UTF-8";
    params.loadErrorUrl = "https://www.oracle.com/database/technologies/instant-client.html";

    const alloc = std.heap.c_allocator;
    const lib_dir_raw: ?[]u8 = compat.getEnvOwned(alloc, lib_dir_env);
    defer if (lib_dir_raw) |d| alloc.free(d);
    var lib_dir_z: ?[:0]u8 = null;
    defer if (lib_dir_z) |d| alloc.free(d);
    if (lib_dir_raw) |d| {
        if (d.len > 0) {
            lib_dir_z = compat.dupeZ(alloc, d) catch null;
            if (lib_dir_z) |p| params.oracleClientLibDir = p.ptr;
        }
    }

    var ctx: ?*c.dpiContext = null;
    var err = std.mem.zeroes(c.dpiErrorInfo);
    if (c.dpiContext_createWithParams(c.DPI_MAJOR_VERSION, c.DPI_MINOR_VERSION, &params, &ctx, &err) != c.DPI_SUCCESS or ctx == null) {
        msg.set("{s}", .{trimMsg(@ptrCast(err.message), err.messageLength)});
        return null;
    }
    context = ctx;
    return ctx;
}

/// Fill `msg` with "<what>: <ODPI-C/Oracle error>" for the last error on this thread.
pub fn setDpiError(msg: *Msg, ctx: *c.dpiContext, comptime what: []const u8) void {
    var err = std.mem.zeroes(c.dpiErrorInfo);
    c.dpiContext_getError(ctx, &err);
    msg.set("duckdb_oracle: " ++ what ++ ": {s}", .{trimMsg(@ptrCast(err.message), err.messageLength)});
}

pub const ClientInfo = struct {
    found: bool,
    version: [64]u8 = undefined,
    version_len: usize = 0,
    message: Msg = .{},
    host_arch: [32]u8 = undefined,
    host_arch_len: usize = 0,
};

extern fn duckdb_oracle_host_arch(buf: [*]u8, buflen: usize) usize;
extern fn duckdb_oracle_find_oci(path: [*]u8, pathlen: usize, arch_buf: [*]u8, archlen: usize) usize;

pub fn hostArch(buf: *[32]u8) []const u8 {
    const n = duckdb_oracle_host_arch(buf, buf.len);
    return buf[0..n];
}

/// Windows-on-ARM / architecture-mismatch guidance for the current process
/// (empty when there is nothing to add). Never fails.
pub fn archHint(out: []u8, client_found: bool) []const u8 {
    var hb: [32]u8 = undefined;
    const host = hostArch(&hb);
    var path: [1024]u8 = undefined;
    var ab: [16]u8 = undefined;
    var oci_arch: ?[]const u8 = null;
    if (!client_found and arch.this_os == .windows) {
        if (duckdb_oracle_find_oci(&path, path.len, &ab, ab.len) > 0) oci_arch = std.mem.sliceTo(&ab, 0);
    }
    return arch.hint(out, arch.this_os, arch.process_arch, host, oci_arch, client_found);
}

pub fn clientInfo() ClientInfo {
    var info: ClientInfo = .{ .found = false };
    info.host_arch_len = hostArch(&info.host_arch).len;
    var hint_buf: [768]u8 = undefined;
    const ctx = getContext(&info.message) orelse {
        const h = archHint(&hint_buf, false);
        if (h.len > 0) {
            const base = info.message;
            info.message.set("{s} | hint: {s}", .{ base.slice(), h });
        }
        return info;
    };
    var v = std.mem.zeroes(c.dpiVersionInfo);
    if (c.dpiContext_getClientVersion(ctx, &v) != c.DPI_SUCCESS) {
        setDpiError(&info.message, ctx, "get client version");
        return info;
    }
    info.found = true;
    const s = std.fmt.bufPrint(&info.version, "{d}.{d}.{d}.{d}.{d}", .{ v.versionNum, v.releaseNum, v.updateNum, v.portReleaseNum, v.portUpdateNum }) catch "";
    info.version_len = s.len;
    const h = archHint(&hint_buf, true);
    if (h.len > 0) info.message.set("OK ({s})", .{h}) else info.message.set("OK", .{});
    return info;
}
