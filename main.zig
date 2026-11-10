const std = @import("std");
const build_options = @import("build_options");
const dsl = @import("src/dsl.zig");
const profile = @import("src/profile.zig");
const trajectory = @import("src/trajectory.zig");
const runner = @import("src/runner.zig");
const dashboard = @import("src/dashboard.zig");
const websocket = @import("src/websocket.zig");
const opentrajectory = @import("src/opentrajectory.zig");

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
const behavior_hash = std.hash.Wyhash.hash(0, source);
const behavior_id = comptime std.fmt.comptimePrint("behavior-{x}", .{behavior_hash});

fn actorType() []const u8 {
    inline for (parsed_spec.steps) |step| {
        if (step.kind == .actor) return step.subject;
    }
    return "";
}

fn subjectId() []const u8 {
    inline for (parsed_spec.steps) |step| {
        if (step.kind == .actor) return step.object;
    }
    return "";
}

fn intentId() []const u8 {
    inline for (parsed_spec.steps, 0..) |step, index| {
        if (step.kind == .wish) {
            return std.fmt.comptimePrint("intent-{x}-{d}", .{ std.hash.Wyhash.hash(0, step.raw), index + 1 });
        }
    }
    return "";
}

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

    const semantic_context = trajectory.SemanticContext{
        .correlation_id = hub.sessionId(),
        .actor_type = comptime actorType(),
        .subject_id = comptime subjectId(),
        .intent_id = comptime intentId(),
        .behavior_id = behavior_id,
    };
    var exporter = try opentrajectory.Exporter.init(
        init.gpa,
        init.io,
        hub.sessionId(),
        build_options.opentrajectory,
        semantic_context,
    );
    defer exporter.deinit();

    var fanout = trajectory.EventFanout{
        .first = hub.eventSink(),
        .second = exporter.eventSink(),
    };
    const sink = fanout.eventSink();
    std.debug.print(
        "ITI — Intent Trajectory Integration\nSpec: {s}\nProfile: {s}\nUI: {s}\n\n",
        .{ build_options.spec, build_options.profile, build_options.ui },
    );

    if (selected_projection == .tui) {
        const suite = dashboard.buildSuite(
            &parsed_spec.steps,
            &dashboard.profileProbes(selected_profile),
            build_options.spec,
            build_options.profile,
        );
        try dashboard.run(suite, .tui, sink, semantic_context, init.gpa, init.io);
        return;
    }

    runner.runParsed(parsed_spec, selected_profile, selected_projection, build_options.profile, sink, semantic_context);
}
