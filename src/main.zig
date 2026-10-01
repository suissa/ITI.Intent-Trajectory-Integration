const std = @import("std");
const build_options = @import("build_options");
const runner = @import("runner.zig");

const source = @embedFile(build_options.spec);

comptime {
    // Force the complete DSL through the parser during compilation.
    _ = @import("dsl.zig").parse(source);
    _ = @import("profile.zig").fromName(build_options.profile);
}

pub fn main() void {
    std.debug.print(
        "ITI — Intent Trajectory Integration\nSpec: {s}\nProfile: {s}\n\n",
        .{ build_options.spec, build_options.profile },
    );
    runner.run(source, build_options.profile);
}
