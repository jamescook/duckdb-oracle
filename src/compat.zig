//! Zig-version compatibility layer for src/ (the extension and its unit tests).
//!
//! Supported: Zig 0.15.2 .. 0.17.x. Every std API that differs between those
//! versions is wrapped here; the rest of src/ calls these wrappers only.
//! Preference order: structural detection (@hasDecl / @hasField / @typeInfo),
//! then builtin.zig_version only when a change is not visible structurally.
//! Each shim names the Zig version that introduced the change. The build
//! script has its own layer: build_compat.zig.
//!
//! Not shims, because one spelling works on every supported version:
//!   - std.mem.trimEnd        (trimRight was a deprecated alias in 0.15, removed in 0.17)
//!   - b.addTranslateC module (replaces @cImport, removed in 0.17; see src/c.zig)
//!
//! Root-module declaration that cannot live here: `_DllMainCRTStartup` in
//! duckdb_oracle.zig (needed on 0.15.x to keep the MinGW CRT entry point; inert on
//! 0.17.0+, whose std/start.zig no longer exports one when libc is linked).
const std = @import("std");

/// Mutex usable without an `Io` instance (a loaded DLL has none).
/// 0.17.0: std.Thread.Mutex was removed; the replacement std.Io.Mutex needs an
/// `io` argument for lock(). duckdb-oracle only guards a one-time, short critical
/// section (lazy ODPI-C context creation), so a spin lock is an adequate
/// fallback. Detected via @hasDecl(std.Thread, "Mutex").
pub const Mutex = if (@hasDecl(std.Thread, "Mutex")) std.Thread.Mutex else SpinMutex;

const SpinMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(m: *SpinMutex) void {
        while (m.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(m: *SpinMutex) void {
        m.locked.store(false, .release);
    }
};

/// 0.17.0: std.fmt.bufPrintZ was removed in favour of
/// bufPrintSentinel(buf, fmt, args, 0) (itself deprecated for mem.printSentinel).
pub fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}![:0]u8 {
    return if (@hasDecl(std.fmt, "bufPrintZ"))
        std.fmt.bufPrintZ(buf, fmt, args)
    else
        std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

/// 0.17.0: Allocator.dupeZ was removed in favour of dupeSentinel(T, m, 0).
pub fn dupeZ(a: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![:0]u8 {
    return if (@hasDecl(std.mem.Allocator, "dupeZ"))
        a.dupeZ(u8, s)
    else
        a.dupeSentinel(u8, s, 0);
}

/// Environment variable lookup from inside a loaded library.
/// 0.16.0: std.process.getEnvVarOwned was removed; environment access moved to
/// std.process.Environ, which is handed to `main` and is not available to a
/// DLL/shared object. duckdb-oracle therefore reads the process environment through
/// a small C helper (src/platform.c: GetEnvironmentVariableW + UTF-8 on
/// Windows, getenv elsewhere), which behaves the same on every Zig version.
pub fn getEnvOwned(a: std.mem.Allocator, name: [:0]const u8) ?[]u8 {
    var len: usize = 0;
    if (duckdb_oracle_getenv(name.ptr, null, 0, &len) == 0) return null;
    const buf = a.alloc(u8, len + 1) catch return null;
    if (duckdb_oracle_getenv(name.ptr, buf.ptr, buf.len, &len) == 0 or len + 1 > buf.len) {
        a.free(buf);
        return null;
    }
    return a.realloc(buf, len) catch buf[0..len];
}

/// Returns 1 if the variable exists; `out_len` receives its UTF-8 length.
/// Copies (NUL-terminated) when `buf` is large enough.
extern fn duckdb_oracle_getenv(name: [*:0]const u8, buf: ?[*]u8, buflen: usize, out_len: *usize) c_int;

test "bufPrintZ / dupeZ" {
    var b: [8]u8 = undefined;
    const z = try bufPrintZ(&b, "a{d}", .{1});
    try std.testing.expectEqualStrings("a1", z);
    try std.testing.expectEqual(@as(u8, 0), z.ptr[z.len]);
    const d = try dupeZ(std.testing.allocator, "xyz");
    defer std.testing.allocator.free(d);
    try std.testing.expectEqual(@as(u8, 0), d.ptr[3]);
}

test "Mutex lock/unlock" {
    var m: Mutex = .{};
    m.lock();
    m.unlock();
    m.lock();
    m.unlock();
}
