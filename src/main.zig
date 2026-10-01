const std = @import("std");
const build_options = @import("build_options");
const runner = @import("runner.zig");

const source = @embedFile(build_options.spec);

comptime {
    _ = @import("dsl.zig").parse(source);
    _ = @import("profile.zig").fromName(build_options.profile);
    _ = @import("trajectory.zig").Projection.fromName(build_options.ui);
}

pub fn main() void {
    std.debug.print(
        "ITI — Intent Trajectory Integration\nSpec: {s}\nProfile: {s}\nUI: {s}\n\n",
        .{ build_options.spec, build_options.profile, build_options.ui },
    );
    runner.run(source, build_options.profile, build_options.ui);
}
