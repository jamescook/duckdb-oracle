//! Zig-version compatibility layer for build.zig.
//!
//! Supported: Zig 0.15.2 .. 0.17.x. Every difference between those versions that
//! the build script touches lives here. Prefer structural feature detection
//! (@hasDecl / @hasField / @typeInfo); compare builtin.zig_version only when a
//! change cannot be detected structurally. Each shim names the version that
//! introduced the change.
const std = @import("std");
const builtin = @import("builtin");

pub const OptimizeMode = std.builtin.OptimizeMode;

/// 0.17.0: std.builtin.Type.Fn replaced `params: []const Param` (with `.type`)
/// by `param_types: []const ?type` (+ `param_attrs`). Detected via @hasField.
pub fn fnParamCount(comptime F: type) usize {
    const info = @typeInfo(F).@"fn";
    if (@hasField(@TypeOf(info), "params")) return info.params.len;
    return info.param_types.len;
}

pub fn fnParamType(comptime F: type, comptime i: usize) type {
    const info = @typeInfo(F).@"fn";
    if (@hasField(@TypeOf(info), "params")) return info.params[i].type.?;
    return info.param_types[i].?;
}

/// Version-neutral optimisation modes.
pub const Optimize = enum {
    debug,
    safe,
    fast,
    small,

    pub fn parse(s: []const u8) ?Optimize {
        const map = .{
            .{ "Debug", .debug },        .{ "debug", .debug },
            .{ "ReleaseSafe", .safe },   .{ "safe", .safe },
            .{ "ReleaseFast", .fast },   .{ "fast", .fast },
            .{ "ReleaseSmall", .small }, .{ "small", .small },
        };
        inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
        return null;
    }
};

/// 0.17.0: std.builtin.OptimizeMode became an alias of std.lang.Optimize with
/// lowercase fields (debug/safe/fast/small); the PascalCase names survive only
/// as deprecated decls (to be removed after 0.18). Detected via @hasField.
pub fn optimizeMode(o: Optimize) OptimizeMode {
    const lowercase = @hasField(OptimizeMode, "safe");
    return switch (o) {
        .debug => if (lowercase) @field(OptimizeMode, "debug") else @field(OptimizeMode, "Debug"),
        .safe => if (lowercase) @field(OptimizeMode, "safe") else @field(OptimizeMode, "ReleaseSafe"),
        .fast => if (lowercase) @field(OptimizeMode, "fast") else @field(OptimizeMode, "ReleaseFast"),
        .small => if (lowercase) @field(OptimizeMode, "small") else @field(OptimizeMode, "ReleaseSmall"),
    };
}

/// `-Doptimize=` accepting both spellings (ReleaseSafe / safe) on every version.
pub fn optimizeOption(b: *std.Build, default: Optimize) Optimize {
    const raw = b.option([]const u8, "optimize", "Optimization mode: Debug|ReleaseSafe|ReleaseFast|ReleaseSmall (or debug|safe|fast|small; default: ReleaseSafe)") orelse
        return default;
    return Optimize.parse(raw) orelse std.process.fatal("unknown -Doptimize={s}", .{raw});
}

/// 0.17.0: Step.Run.captureStdOut() gained an `options` parameter
/// (CapturedStdIo.Options). Detected from the function's parameter count.
pub fn captureStdOut(run: *std.Build.Step.Run) std.Build.LazyPath {
    const n = comptime fnParamCount(@TypeOf(std.Build.Step.Run.captureStdOut));
    return if (n == 1) run.captureStdOut() else run.captureStdOut(.{});
}

/// 0.17.0: `Build.build_root: Cache.Directory` was replaced by
/// `Build.root: Cache.Path`. Returns the package root as a path string.
pub fn buildRootPath(b: *std.Build) []const u8 {
    return if (@hasField(std.Build, "build_root"))
        b.build_root.path orelse "."
    else
        b.root.toString(b.allocator) catch ".";
}

/// 0.17.0: the stderr behaviour of Build.runAllowFail() changed from
/// std.process.Child.StdIo (`.Ignore`) to std.process.SpawnOptions.StdIo, a
/// tagged union with lowercase tags (`.ignore`). Detected from the parameter type.
pub fn runAllowFailQuiet(b: *std.Build, argv: []const []const u8, code: *u8) ![]u8 {
    const StdIo = fnParamType(@TypeOf(std.Build.runAllowFail), 3);
    const ignore: StdIo = if (@hasField(StdIo, "ignore")) .ignore else .Ignore;
    return b.runAllowFail(argv, code, ignore);
}
