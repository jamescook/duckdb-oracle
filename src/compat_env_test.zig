//! compat.getEnvOwned() against the real C helper (src/platform.c is linked
//! into the unit-test binary).
const std = @import("std");
const compat = @import("compat.zig");

test "getEnvOwned reads PATH and misses unknown variables" {
    const a = std.testing.allocator;
    const path = compat.getEnvOwned(a, "PATH") orelse return error.PathNotSet;
    defer a.free(path);
    try std.testing.expect(path.len > 0);
    try std.testing.expect(compat.getEnvOwned(a, "DUCKDB_ORACLE_SURELY_UNSET_VARIABLE_42") == null);
}
