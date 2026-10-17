//! Client locator module: decides WHICH Oracle client library gets loaded, and
//! explains the decision.
//!
//! Why this exists (review F4, F7). ODPI-C's own Windows loader uses the ANSI
//! `LoadLibraryA` (a UTF-8 directory name with non-ASCII characters never
//! loads) and falls back to the default DLL search order, which includes the
//! current directory (a planted `oci.dll` is picked up). The diagnostic that
//! reported "the first oci.dll on the search path" used a third, different
//! search (`SearchPathW`) and could name a file the loader would not pick.
//!
//! On Windows this module therefore makes the decision itself and loads the DLL
//! with the wide-character API; ODPI-C then finds the module already loaded.
//! On other platforms the dynamic loader (LD_LIBRARY_PATH, ldconfig,
//! $ORACLE_HOME/lib) already does the right thing and ODPI-C is left alone.
//!
//! The search policy is pure and generic over an OS adapter, so it is tested on
//! any host with a fake. Adapter interface (all paths UTF-8):
//!   fileArch(path) ?[]const u8      "x64"/"arm64"/"x86"/... from the PE header, null if no such file
//!   load(path) ?u32                 null on success, else the OS error code
//!   moduleDir() ?[]const u8         directory of this extension
//!   appDir() ?[]const u8            directory of the host executable (duckdb.exe)
//!   pathVar() ?[]const u8           the PATH environment variable
//!
//! Search order:
//!   * DUCKDB_ORACLE_CLIENT_LIB_DIR set: that directory only (exclusive).
//!   * otherwise: the extension's directory, the host executable's directory,
//!     then each ABSOLUTE entry of PATH, in order. The current directory and
//!     relative PATH entries are never searched.
//! An oci.dll of the wrong architecture is skipped (and reported). One of the
//! right architecture that fails to load (typically a missing dependency)
//! stops the search with that error rather than silently trying another.
const std = @import("std");
const compat = @import("compat.zig");

pub const lib_name = "oci.dll";

pub const Status = enum { loaded, not_found, load_failed };

pub const Result = struct {
    status: Status = .not_found,
    /// the file that was loaded, or the one that failed to load
    path: [512]u8 = undefined,
    path_len: usize = 0,
    /// architecture of the first oci.dll met in search order (loaded, skipped or failed)
    first_arch: [16]u8 = undefined,
    first_arch_len: usize = 0,
    /// human readable explanation
    detail: [1280]u8 = undefined,
    detail_len: usize = 0,

    pub fn pathSlice(self: *const Result) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn firstArch(self: *const Result) ?[]const u8 {
        return if (self.first_arch_len == 0) null else self.first_arch[0..self.first_arch_len];
    }
    pub fn detailSlice(self: *const Result) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

pub fn locate(os: anytype, lib_dir: ?[]const u8, process_arch: []const u8) Result {
    var r: Result = .{};
    var skipped_buf: [512]u8 = undefined;
    var skipped: std.ArrayList(u8) = .initBuffer(&skipped_buf);
    var detail: std.ArrayList(u8) = .initBuffer(&r.detail);

    var status: ?Status = null;
    if (lib_dir) |dir| {
        // an explicit directory is exclusive: never fall back to anything else
        status = tryDir(os, &r, &skipped, &detail, process_arch, dir);
    } else {
        if (os.moduleDir()) |dir| status = tryDir(os, &r, &skipped, &detail, process_arch, dir);
        if (status == null) if (os.appDir()) |dir| {
            status = tryDir(os, &r, &skipped, &detail, process_arch, dir);
        };
        if (status == null) if (os.pathVar()) |path| {
            var it = std.mem.splitScalar(u8, path, ';');
            while (it.next()) |raw| {
                const entry = cleanPathEntry(raw);
                if (entry.len == 0 or !isAbsolute(entry)) continue; // never the current directory
                status = tryDir(os, &r, &skipped, &detail, process_arch, entry);
                if (status != null) break;
            }
        };
    }

    r.status = status orelse .not_found;
    switch (r.status) {
        .loaded => if (skipped.items.len > 0) {
            detail.printBounded("skipped {s}", .{skipped.items}) catch {};
        },
        .load_failed => {}, // tryDir wrote the explanation
        .not_found => {
            if (lib_dir) |dir| {
                detail.printBounded("no {s} in DUCKDB_ORACLE_CLIENT_LIB_DIR={s} (that directory is searched exclusively)", .{ lib_name, dir }) catch {};
            } else {
                detail.printBounded("no {s} {s} found in the extension's directory, the directory of the host executable or the absolute entries of PATH (the current directory is never searched)", .{ process_arch, lib_name }) catch {};
            }
            if (skipped.items.len > 0) {
                detail.printBounded("; skipped {s}where this process needs {s}", .{ skipped.items, process_arch }) catch {};
            }
        },
    }
    r.detail_len = detail.items.len;
    return r;
}

/// Probe `<dir>\oci.dll`. Returns the final status when the search is decided
/// (loaded, or found-but-unloadable), null to continue with the next directory.
fn tryDir(os: anytype, r: *Result, skipped: *std.ArrayList(u8), detail: *std.ArrayList(u8), process_arch: []const u8, dir: []const u8) ?Status {
    var buf: [r.path.len]u8 = undefined;
    const trimmed = std.mem.trimEnd(u8, dir, "\\/");
    const full = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ trimmed, lib_name }) catch return null; // path too long to be a real client
    const arch = os.fileArch(full) orelse return null;

    if (r.first_arch_len == 0) {
        const n = @min(arch.len, r.first_arch.len);
        @memcpy(r.first_arch[0..n], arch[0..n]);
        r.first_arch_len = n;
    }
    if (!std.mem.eql(u8, arch, process_arch)) {
        skipped.printBounded("{s} is {s}; ", .{ full, arch }) catch {};
        return null;
    }

    @memcpy(r.path[0..full.len], full);
    r.path_len = full.len;
    if (os.load(full)) |code| {
        detail.printBounded("{s} was found but Windows could not load it (error {d}: {s})", .{ full, code, loadErrorCause(code) }) catch {};
        return .load_failed;
    }
    return .loaded;
}

fn loadErrorCause(code: u32) []const u8 {
    return switch (code) {
        126 => "a DLL that oci.dll depends on is missing; keep all Instant Client files together in one directory and install the Visual C++ x64 runtime the client needs",
        193 => "not a valid application for this process architecture",
        5 => "access denied",
        else => "see the Windows error code",
    };
}

fn cleanPathEntry(raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

/// "X:\..." or "X:/..." or a UNC path. Anything else depends on the current directory.
fn isAbsolute(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return std.mem.startsWith(u8, p, "\\\\");
}

/// The Windows adapter (primitives in platform.c). Only referenced on Windows.
pub const WindowsOs = struct {
    extern fn duckdb_oracle_file_arch(utf8_path: [*:0]const u8) ?[*:0]const u8;
    extern fn duckdb_oracle_load_library(utf8_path: [*:0]const u8, err: *c_ulong) c_int;
    extern fn duckdb_oracle_module_dir(buf: [*]u8, buflen: usize) usize;
    extern fn duckdb_oracle_app_dir(buf: [*]u8, buflen: usize) usize;

    module_buf: [1024]u8 = undefined,
    app_buf: [1024]u8 = undefined,
    path_owned: ?[]u8 = null,

    pub fn deinit(self: *WindowsOs) void {
        if (self.path_owned) |p| std.heap.c_allocator.free(p);
        self.path_owned = null;
    }

    pub fn fileArch(self: *WindowsOs, path: []const u8) ?[]const u8 {
        _ = self;
        var z: [520:0]u8 = undefined;
        if (path.len >= z.len) return null;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        const a = duckdb_oracle_file_arch(&z) orelse return null;
        return std.mem.span(a);
    }

    pub fn load(self: *WindowsOs, path: []const u8) ?u32 {
        _ = self;
        var z: [520:0]u8 = undefined;
        if (path.len >= z.len) return 123; // ERROR_INVALID_NAME
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        var err: c_ulong = 0;
        if (duckdb_oracle_load_library(&z, &err) != 0) return null;
        return @intCast(err);
    }

    pub fn moduleDir(self: *WindowsOs) ?[]const u8 {
        const n = duckdb_oracle_module_dir(&self.module_buf, self.module_buf.len);
        return if (n == 0) null else self.module_buf[0..n];
    }

    pub fn appDir(self: *WindowsOs) ?[]const u8 {
        const n = duckdb_oracle_app_dir(&self.app_buf, self.app_buf.len);
        return if (n == 0) null else self.app_buf[0..n];
    }

    pub fn pathVar(self: *WindowsOs) ?[]const u8 {
        if (self.path_owned == null) self.path_owned = compat.getEnvOwned(std.heap.c_allocator, "PATH");
        return self.path_owned;
    }
};

// ---------------------------------------------------------------------------
// Tests with a fake operating system
// ---------------------------------------------------------------------------
const testing = std.testing;

const FakeOs = struct {
    const File = struct { path: []const u8, arch: []const u8, load_error: ?u32 = null };
    files: []const File,
    module_dir: ?[]const u8 = "C:\\Users\\me\\.duckdb\\extensions\\v1.5.6\\windows_amd64",
    app_dir: ?[]const u8 = "C:\\tools\\duckdb",
    path: ?[]const u8 = null,
    /// every path probed with fileArch, in order
    probed: *std.ArrayList([]const u8),

    pub fn fileArch(self: FakeOs, p: []const u8) ?[]const u8 {
        // copy: the caller's buffer does not outlive this call
        self.probed.append(testing.allocator, testing.allocator.dupe(u8, p) catch unreachable) catch unreachable;
        for (self.files) |f| if (std.ascii.eqlIgnoreCase(f.path, p)) return f.arch;
        return null;
    }
    pub fn load(self: FakeOs, p: []const u8) ?u32 {
        for (self.files) |f| if (std.ascii.eqlIgnoreCase(f.path, p)) return f.load_error;
        return 5;
    }
    pub fn moduleDir(self: FakeOs) ?[]const u8 {
        return self.module_dir;
    }
    pub fn appDir(self: FakeOs) ?[]const u8 {
        return self.app_dir;
    }
    pub fn pathVar(self: FakeOs) ?[]const u8 {
        return self.path;
    }
};

fn freeProbed(list: *std.ArrayList([]const u8)) void {
    for (list.items) |p| testing.allocator.free(p);
    list.deinit(testing.allocator);
}

fn run(files: []const FakeOs.File, path: ?[]const u8, lib_dir: ?[]const u8) !struct { r: Result, probed: std.ArrayList([]const u8) } {
    // the fake keeps a pointer to the list, so the list header lives on the heap while locate() runs
    const holder = try testing.allocator.create(std.ArrayList([]const u8));
    defer testing.allocator.destroy(holder);
    holder.* = .empty;
    const os: FakeOs = .{ .files = files, .path = path, .probed = holder };
    const r = locate(os, lib_dir, "x64");
    return .{ .r = r, .probed = holder.* };
}

test "PATH entry is found and loaded" {
    var out = try run(&.{.{ .path = "D:\\ic\\oci.dll", .arch = "x64" }}, "C:\\Windows;D:\\ic", null);
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.loaded, out.r.status);
    try testing.expectEqualStrings("D:\\ic\\oci.dll", out.r.pathSlice());
    try testing.expectEqualStrings("x64", out.r.firstArch().?);
}

test "search order: extension directory, then the host executable's directory, then PATH" {
    var out = try run(&.{
        .{ .path = "D:\\ic\\oci.dll", .arch = "x64" },
        .{ .path = "C:\\tools\\duckdb\\oci.dll", .arch = "x64" },
        .{ .path = "C:\\Users\\me\\.duckdb\\extensions\\v1.5.6\\windows_amd64\\oci.dll", .arch = "x64" },
    }, "D:\\ic", null);
    defer freeProbed(&out.probed);
    try testing.expectEqualStrings("C:\\Users\\me\\.duckdb\\extensions\\v1.5.6\\windows_amd64\\oci.dll", out.r.pathSlice());
    // the host directory beats PATH
    var out2 = try run(&.{
        .{ .path = "D:\\ic\\oci.dll", .arch = "x64" },
        .{ .path = "C:\\tools\\duckdb\\oci.dll", .arch = "x64" },
    }, "D:\\ic", null);
    defer freeProbed(&out2.probed);
    try testing.expectEqualStrings("C:\\tools\\duckdb\\oci.dll", out2.r.pathSlice());
}

test "the current directory and relative PATH entries are never searched (F7)" {
    var out = try run(&.{
        .{ .path = ".\\oci.dll", .arch = "x64" },
        .{ .path = "oci.dll", .arch = "x64" },
        .{ .path = "bin\\oci.dll", .arch = "x64" },
        .{ .path = "..\\ic\\oci.dll", .arch = "x64" },
    }, ".;bin;..\\ic;;C:\\Windows", null);
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.not_found, out.r.status);
    for (out.probed.items) |p| {
        try testing.expect(p.len > 2 and (p[1] == ':' or std.mem.startsWith(u8, p, "\\\\")));
    }
}

test "PATH entries may be quoted and may end with a separator" {
    var out = try run(&.{.{ .path = "D:\\Program Files\\ic\\oci.dll", .arch = "x64" }}, "\"D:\\Program Files\\ic\\\"", null);
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.loaded, out.r.status);
    try testing.expectEqualStrings("D:\\Program Files\\ic\\oci.dll", out.r.pathSlice());
}

test "DUCKDB_ORACLE_CLIENT_LIB_DIR is exclusive, even when other directories have a client" {
    var out = try run(&.{
        .{ .path = "D:\\good\\oci.dll", .arch = "x64" },
        .{ .path = "C:\\tools\\duckdb\\oci.dll", .arch = "x64" },
    }, "D:\\good", "E:\\empty");
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.not_found, out.r.status);
    try testing.expectEqual(@as(usize, 1), out.probed.items.len);
    try testing.expectEqualStrings("E:\\empty\\oci.dll", out.probed.items[0]);
    try testing.expect(std.mem.indexOf(u8, out.r.detailSlice(), "DUCKDB_ORACLE_CLIENT_LIB_DIR") != null);
    try testing.expect(std.mem.indexOf(u8, out.r.detailSlice(), "E:\\empty") != null);
}

test "LIB_DIR with non-ASCII characters is handled as UTF-8 text (F4)" {
    var out = try run(&.{.{ .path = "C:\\Users\\M\xc3\xbcller-\xc3\xa9\\ic\\oci.dll", .arch = "x64" }}, null, "C:\\Users\\M\xc3\xbcller-\xc3\xa9\\ic");
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.loaded, out.r.status);
}

test "a 32-bit oci.dll is skipped and reported; a later 64-bit one is used" {
    var out = try run(&.{
        .{ .path = "C:\\old32\\oci.dll", .arch = "x86" },
        .{ .path = "D:\\ic\\oci.dll", .arch = "x64" },
    }, "C:\\old32;D:\\ic", null);
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.loaded, out.r.status);
    try testing.expectEqualStrings("D:\\ic\\oci.dll", out.r.pathSlice());
    try testing.expectEqualStrings("x86", out.r.firstArch().?); // the first one met, as before
    try testing.expect(std.mem.indexOf(u8, out.r.detailSlice(), "C:\\old32\\oci.dll is x86") != null);
}

test "only a 32-bit client: not found, with the skipped file and its architecture named" {
    var out = try run(&.{.{ .path = "C:\\old32\\oci.dll", .arch = "x86" }}, "C:\\old32", null);
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.not_found, out.r.status);
    try testing.expectEqualStrings("x86", out.r.firstArch().?);
    const d = out.r.detailSlice();
    try testing.expect(std.mem.indexOf(u8, d, "C:\\old32\\oci.dll is x86") != null);
    try testing.expect(std.mem.indexOf(u8, d, "x64") != null); // says which architecture is needed
}

test "a right-architecture DLL that cannot load stops the search with the OS error" {
    var out = try run(&.{
        .{ .path = "C:\\broken\\oci.dll", .arch = "x64", .load_error = 126 },
        .{ .path = "D:\\ic\\oci.dll", .arch = "x64" },
    }, "C:\\broken;D:\\ic", null);
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.load_failed, out.r.status);
    try testing.expectEqualStrings("C:\\broken\\oci.dll", out.r.pathSlice());
    const d = out.r.detailSlice();
    try testing.expect(std.mem.indexOf(u8, d, "126") != null);
    try testing.expect(std.mem.indexOf(u8, d, "depend") != null); // names the likely cause
}

test "nothing found anywhere: not found, nothing loaded" {
    var out = try run(&.{}, "C:\\Windows;C:\\Windows\\System32", null);
    defer freeProbed(&out.probed);
    try testing.expectEqual(Status.not_found, out.r.status);
    try testing.expectEqual(@as(?[]const u8, null), out.r.firstArch());
    try testing.expect(out.r.detailSlice().len > 0);
}

test "missing PATH, module and app directories are tolerated" {
    var probed: std.ArrayList([]const u8) = .empty;
    defer probed.deinit(testing.allocator);
    const os: FakeOs = .{ .files = &.{}, .module_dir = null, .app_dir = null, .path = null, .probed = &probed };
    const r = locate(os, null, "x64");
    try testing.expectEqual(Status.not_found, r.status);
    try testing.expectEqual(@as(usize, 0), probed.items.len);
}
