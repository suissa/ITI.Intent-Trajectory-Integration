const std = @import("std");
const build_options = @import("build_options");
const dsl = @import("src/dsl.zig");
const profile = @import("src/profile.zig");
const trajectory = @import("src/trajectory.zig");
const runner = @import("src/runner.zig");
const dashboard = @import("src/dashboard.zig");
const websocket = @import("src/websocket.zig");

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

pub fn main(init: std.process.Init) !void {
    var hub = try websocket.Hub.init(init.io);
    defer hub.deinit();

    var server_group: std.Io.Group = .init;
    defer server_group.cancel(init.io);
    try server_group.concurrent(init.io, websocket.serve, .{
        init.io,
        init.gpa,
        &hub,
        @as(u16, 7331),
    });

    while (hub.serverState() == 0) {
        try init.io.sleep(.fromMilliseconds(2), .awake);
    }
    if (hub.serverState() == 2) return error.WebSocketServerStartFailed;

    const sink = hub.eventSink();
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
        try dashboard.run(suite, .tui, sink);
        return;
    }

    runner.runParsed(parsed_spec, selected_profile, selected_projection, build_options.profile, sink);
}
