//! Unit test root: pure modules only (no DuckDB or OCI calls).
test {
    _ = @import("convert.zig");
    _ = @import("column.zig");
    _ = @import("arch.zig");
    _ = @import("timeouts.zig");
    _ = @import("cursor.zig");
    _ = @import("compat.zig");
    _ = @import("compat_env_test.zig");
}
