pub const packages = struct {
    pub const @"vendor/tui" = struct {
        pub const build_root = "/workspace/vendor/tui";
        pub const build_zig = @import("vendor/tui");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "tui", "vendor/tui" },
};
