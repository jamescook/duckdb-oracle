//! duckdb-oracle build script (Zig 0.15.2 .. 0.17.x; version shims in build_compat.zig).
//!
//! `zig build` cross-compiles the extension for every platform in `-Dplatform`
//! (default: linux_amd64 + windows_amd64), appends the official DuckDB
//! extension metadata footer with the vendored, unmodified
//! `append_extension_metadata.py` from duckdb/extension-ci-tools (branch v1.5.6)
//! and installs:
//!
//!   zig-out/<platform>/duckdb_oracle.duckdb_extension
//!   zig-out/dist/duckdb_oracle-<platform>.zip   (shipped form)
//!
//! DuckDB derives the extension name - and the init symbol it resolves,
//! <name>_init_c_api - from the FILE NAME, so the file must always be called
//! exactly duckdb_oracle.duckdb_extension. The platform goes into the zip name
//! only; each zip contains that one file (tools/package.py).
//!
//! DuckDB version: `-Dduckdb-version=vX.Y.Z` selects the C Extension API version
//! the binary targets. It is the version written into the footer and requested
//! from DuckDB via get_api(); DuckDB loads a C_STRUCT extension on any 1.x
//! release >= that version. Default: v1.2.0, the lowest version the code needs
//! (and the first release with the C Extension API). The headers are always the
//! vendored v1.5.6 ones (the tested baseline); they gate every API by version, so
//! selecting an older target makes use of any newer function a compile error.
//!
//! Other steps:
//!   zig build test           Zig unit tests (type conversion code, native host)
//!   zig build sqllogictest   SQLLogicTests against the stock DuckDB Python wheel
//!                            (needs a python with duckdb (e.g. 1.5.6) + duckdb_sqllogictest,
//!                            pass it with -Dpython=/path/to/python)
const std = @import("std");
const Build = std.Build;
// All Zig-version differences (0.15.2 .. 0.17.x) live in build_compat.zig.
const compat = @import("build_compat.zig");

/// DuckDB release whose C API headers are vendored = tested baseline.
const duckdb_headers_version = "v1.5.6";
/// Lowest C API version the code needs (every function used is in the v1.2.0
/// stable surface; see REPORT.md section 7). Also the floor of the C extension API.
const default_target_version = "v1.2.0";

const Platform = enum {
    linux_amd64,
    windows_amd64,
    /// Same binary as linux_amd64, only the footer label differs: DuckDB
    /// v1.2.x official Linux builds report the platform `linux_amd64_gcc4`.
    /// Not built by default; use -Dplatform=linux_amd64_gcc4.
    linux_amd64_gcc4,
    /// Windows on ARM (aarch64-windows-gnu). Same pure-C ABI reasoning as
    /// windows_amd64. Note: Oracle ships no ARM64 Instant Client for Windows
    /// (see README), so this build can load but cannot reach Oracle.
    windows_arm64,
    /// Apple Silicon macOS (aarch64-macos). Oracle ships a macOS ARM64 Instant Client.
    osx_arm64,

    fn target(self: Platform, b: *Build) Build.ResolvedTarget {
        return b.resolveTargetQuery(switch (self) {
            // glibc 2.28 = manylinux_2_28, the baseline DuckDB's own linux_amd64
            // binaries are built against. Keeps the .so loadable on older distros.
            .linux_amd64, .linux_amd64_gcc4 => .{
                .cpu_arch = .x86_64,
                .os_tag = .linux,
                .abi = .gnu,
                .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 },
            },
            // MinGW-w64 ABI. Only a pure C ABI crosses the DuckDB <-> extension
            // boundary (duckdb_extension_access + function pointer struct), so the
            // C++ runtime mismatch that forces MSVC for C++ extensions does not
            // apply. Zig ships the MinGW CRT and links it statically against UCRT,
            // so no SDK, no MSVC and no libgcc/libstdc++ DLLs are needed.
            .windows_amd64 => .{
                .cpu_arch = .x86_64,
                .os_tag = .windows,
                .abi = .gnu,
            },
            .windows_arm64 => .{
                .cpu_arch = .aarch64,
                .os_tag = .windows,
                .abi = .gnu,
            },
            .osx_arm64 => .{
                .cpu_arch = .aarch64,
                .os_tag = .macos,
            },
        });
    }
};

pub fn build(b: *Build) void {
    const opt = compat.optimizeOption(b, .safe);
    const optimize = compat.optimizeMode(opt);
    const platforms = b.option([]const Platform, "platform", "Platform(s) to build (default: linux_amd64, windows_amd64, windows_arm64)") orelse
        &[_]Platform{ .linux_amd64, .windows_amd64, .windows_arm64 };
    const capi_version = b.option([]const u8, "duckdb-version", "Minimum DuckDB / C API version to target, encoded in the footer (default: " ++ default_target_version ++ "; allowed v1.2.0 .. " ++ duckdb_headers_version ++ ")") orelse
        b.option([]const u8, "capi-version", "Deprecated alias of -Dduckdb-version") orelse default_target_version;
    const ext_version = b.option([]const u8, "extension-version", "Extension version for the footer (default: git describe)") orelse
        detectGitVersion(b);
    const python = b.option([]const u8, "python", "Python interpreter used for the metadata script / sqllogictest") orelse
        (if (b.graph.host.result.os.tag == .windows) "python" else "python3");

    if (capi_version.len < 2 or capi_version[0] != 'v')
        std.process.fatal("-Dduckdb-version must look like v1.2.0, got '{s}'", .{capi_version});
    const semver = std.SemanticVersion.parse(capi_version[1..]) catch
        std.process.fatal("-Dduckdb-version must look like v1.2.0, got '{s}'", .{capi_version});
    const lo = std.SemanticVersion.parse(default_target_version[1..]) catch unreachable;
    const hi = std.SemanticVersion.parse(duckdb_headers_version[1..]) catch unreachable;
    if (semver.order(lo) == .lt or semver.order(hi) == .gt)
        std.process.fatal("-Dduckdb-version={s} is outside the supported range {s} .. {s} (C extension API floor .. vendored headers)", .{ capi_version, default_target_version, duckdb_headers_version });

    const metadata_script = b.path("third_party/extension-ci-tools/append_extension_metadata.py");
    const duckdb_headers = b.path("third_party/duckdb/" ++ duckdb_headers_version);
    const odpi_include = b.path("third_party/odpi/include");

    const check_step = b.step("check", "Compile the extension without writing the footer");
    const slt_step = b.step("sqllogictest", "Run SQLLogicTests (no Oracle client paths) with the stock duckdb Python wheel");

    for (platforms) |platform| {
        const pname = @tagName(platform);
        const target = platform.target(b);

        const mod = b.createModule(.{
            .root_source_file = b.path("src/duckdb_oracle.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            .strip = opt != .debug,
        });
        const opts = b.addOptions();
        opts.addOption([]const u8, "extension_version", ext_version);
        opts.addOption([]const u8, "capi_version", capi_version);
        opts.addOption([]const u8, "duckdb_headers_version", duckdb_headers_version);
        mod.addOptions("build_options", opts);
        mod.addImport("c_headers", cHeaders(b, target, semver));

        const capi_defines = [_][2][]const u8{
            .{ "DUCKDB_EXTENSION_API_VERSION_MAJOR", b.fmt("{d}", .{semver.major}) },
            .{ "DUCKDB_EXTENSION_API_VERSION_MINOR", b.fmt("{d}", .{semver.minor}) },
            .{ "DUCKDB_EXTENSION_API_VERSION_PATCH", b.fmt("{d}", .{semver.patch}) },
        };
        for (capi_defines) |d| mod.addCMacro(d[0], d[1]);
        mod.addCMacro("DUCKDB_EXTENSION_NAME", "duckdb_oracle");
        mod.addCMacro("DUCKDB_BUILD_LOADABLE_EXTENSION", "1");
        mod.addIncludePath(duckdb_headers);
        mod.addIncludePath(odpi_include);
        mod.addIncludePath(b.path("src"));

        // Platform helpers (C, hidden visibility).
        mod.addCSourceFiles(.{
            .root = b.path("src"),
            .files = &.{"platform.c"},
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-fvisibility=hidden", "-fno-sanitize=undefined" },
        });
        // ODPI-C, single translation unit. UBSan is disabled for third-party C
        // code so that benign UB can never turn into a trap inside DuckDB.
        mod.addCSourceFiles(.{
            .root = b.path("third_party/odpi"),
            .files = &.{"embed/dpi.c"},
            .flags = &.{ "-std=c11", "-fvisibility=hidden", "-fno-sanitize=undefined", "-Wno-everything" },
        });
        if (platform == .linux_amd64 or platform == .linux_amd64_gcc4) {
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("pthread", .{});
        }

        const lib = b.addLibrary(.{
            .name = "duckdb_oracle",
            .linkage = .dynamic,
            .root_module = mod,
        });
        // duckdb_ext_api is the only "external" thing and it lives inside the
        // library itself, so no undefined symbols are allowed.
        lib.linker_allow_shlib_undefined = false;
        check_step.dependOn(&lib.step);

        const filename = "duckdb_oracle.duckdb_extension";
        const footer = Build.Step.Run.create(b, b.fmt("footer {s} {s}", .{ capi_version, pname }));
        footer.addArg(python);
        footer.addFileArg(metadata_script);
        footer.addArgs(&.{ "--extension-name", "duckdb_oracle" });
        footer.addArgs(&.{ "--extension-version", ext_version });
        footer.addArgs(&.{ "--duckdb-platform", pname });
        footer.addArgs(&.{ "--duckdb-version", capi_version });
        footer.addArgs(&.{ "--abi-type", "C_STRUCT" });
        footer.addArg("--library-file");
        footer.addArtifactArg(lib);
        footer.addArg("--out-file");
        const ext_path = footer.addOutputFileArg(filename);
        _ = compat.captureStdOut(footer); // keep `zig build` quiet

        const install = b.addInstallFileWithDir(ext_path, .{ .custom = pname }, filename);
        b.getInstallStep().dependOn(&install.step);

        // Shipped form: duckdb_oracle-<platform>.zip containing exactly
        // duckdb_oracle.duckdb_extension (the name DuckDB needs for LOAD).
        const zip_name = b.fmt("duckdb_oracle-{s}.zip", .{pname});
        const pkg = Build.Step.Run.create(b, b.fmt("package {s}", .{zip_name}));
        pkg.addArg(python);
        pkg.addFileArg(b.path("tools/package.py"));
        pkg.addArg("--extension");
        pkg.addFileArg(ext_path);
        pkg.addArg("--out");
        const zip_path = pkg.addOutputFileArg(zip_name);
        const install_zip = b.addInstallFileWithDir(zip_path, .{ .custom = "dist" }, zip_name);
        b.getInstallStep().dependOn(&install_zip.step);

        if (b.graph.host.result.os.tag == target.result.os.tag and b.graph.host.result.cpu.arch == target.result.cpu.arch) {
            const slt = Build.Step.Run.create(b, b.fmt("sqllogictest {s}", .{pname}));
            slt.addArgs(&.{ python, "-m", "duckdb_sqllogictest", "--test-dir" });
            slt.addDirectoryArg(b.path("test/sql"));
            slt.addArg("--external-extension");
            slt.addFileArg(ext_path);
            slt.has_side_effects = true;
            slt_step.dependOn(&slt.step);
        }
    }

    // Unit tests for the pure conversion code, using hand-built dpiData values.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = compat.optimizeMode(.debug),
        .link_libc = true,
    });
    test_mod.addImport("c_headers", cHeaders(b, b.graph.host, semver));
    test_mod.addCSourceFiles(.{ .root = b.path("src"), .files = &.{"platform.c"}, .flags = &.{ "-std=c11", "-fno-sanitize=undefined" } });
    if (b.graph.host.result.os.tag == .linux) test_mod.linkSystemLibrary("dl", .{});
    const unit = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);
}

/// C headers (DuckDB C API + ODPI-C) as a Zig module, translated for `target`.
fn cHeaders(b: *Build, target: Build.ResolvedTarget, semver: std.SemanticVersion) *Build.Module {
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers.h"),
        .target = target,
        .optimize = compat.optimizeMode(.debug),
        .link_libc = true,
    });
    tc.addIncludePath(b.path("third_party/duckdb/" ++ duckdb_headers_version));
    tc.addIncludePath(b.path("third_party/odpi/include"));
    tc.defineCMacro("DUCKDB_EXTENSION_API_VERSION_MAJOR", b.fmt("{d}", .{semver.major}));
    tc.defineCMacro("DUCKDB_EXTENSION_API_VERSION_MINOR", b.fmt("{d}", .{semver.minor}));
    tc.defineCMacro("DUCKDB_EXTENSION_API_VERSION_PATCH", b.fmt("{d}", .{semver.patch}));
    return tc.createModule();
}

fn detectGitVersion(b: *Build) []const u8 {
    var code: u8 = 0;
    const out = compat.runAllowFailQuiet(b, &.{ "git", "-C", compat.buildRootPath(b), "describe", "--tags", "--match", "v[0-9]*", "--always", "--dirty" }, &code) catch
        return "v0.1.0";
    const trimmed = std.mem.trim(u8, out, " \r\n");
    return if (trimmed.len == 0) "v0.1.0" else trimmed;
}
