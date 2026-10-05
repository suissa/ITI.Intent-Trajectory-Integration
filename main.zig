const std = @import("std");
const build_options = @import("build_options");
const dsl = @import("src/dsl.zig");
const profile = @import("src/profile.zig");
const trajectory = @import("src/trajectory.zig");
const runner = @import("src/runner.zig");
const dashboard = @import("src/dashboard.zig");

const source = @embedFile(build_options.spec);

const parsed_spec = blk: {
    @setEvalBranchQuota(100_000);
    break :blk dsl.parse(source);
};

const selected_profile = blk: {
    @setEvalBranchQuota(10_000);
    break :blk profile.fromName(build_options.profile);
};

const selected_projection = trajectory.Projection.fromName(build_options.ui);

pub fn main() !void {
    std.debug.print(
        "ITI — Intent Trajectory Integration\nSpec: {s}\nProfile: {s}\nUI: {s}\n\n",
        .{ build_options.spec, build_options.profile, build_options.ui },
    );

    if (selected_projection == .tui) {
        const suite = dashboard.buildSuite(
            parsed_spec,
            dashboard.profileProbes(selected_profile),
            build_options.spec,
            build_options.profile,
        );
        try dashboard.run(suite, .tui);
        return;
    }

    runner.runParsed(parsed_spec, selected_profile, selected_projection, build_options.profile);
}
