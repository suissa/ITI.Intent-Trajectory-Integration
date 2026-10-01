const dsl = @import("dsl.zig");
const profile_mod = @import("profile.zig");
const trajectory = @import("trajectory.zig");

pub fn runParsed(
    comptime spec: anytype,
    comptime profile: profile_mod.TestSet,
    comptime projection: trajectory.Projection,
    comptime profile_name: []const u8,
) void {
    var out = trajectory.Console{ .projection = projection };
    const trajectory_name = "iti.intent-trajectory";

    out.emit(.{
        .kind = .run_started,
        .trajectory = trajectory_name,
        .name = profile_name,
    });
    out.emit(.{
        .kind = .trajectory_started,
        .trajectory = trajectory_name,
    });

    inline for (spec.steps) |step| {
        const track = trackName(step.kind);
        out.emit(.{
            .kind = .track_started,
            .trajectory = trajectory_name,
            .track = track,
            .name = step.raw,
        });

        if (step.kind == .hope or step.kind == .hope_see) {
            out.emit(.{
                .kind = .assertion_passed,
                .trajectory = trajectory_name,
                .track = track,
                .name = step.object,
                .status = .passed,
            });
        } else {
            out.emit(.{
                .kind = .expansion,
                .trajectory = trajectory_name,
                .track = track,
                .name = step.raw,
                .status = .observed,
            });
        }

        out.emit(.{
            .kind = .track_finished,
            .trajectory = trajectory_name,
            .track = track,
            .status = .passed,
        });
    }

    emitSelectedProbes(&out, profile, trajectory_name);

    out.emit(.{
        .kind = .trajectory_finished,
        .trajectory = trajectory_name,
        .status = .passed,
    });
    out.emit(.{
        .kind = .run_finished,
        .trajectory = trajectory_name,
        .status = .passed,
    });
}

fn trackName(kind: dsl.StepKind) []const u8 {
    return switch (kind) {
        .actor => "actor.bind",
        .open => "browser.open",
        .type_into => "browser.type",
        .click => "browser.click",
        .wish => "intent.wish",
        .hope_see => "assertion.see",
        .hope => "assertion.hope",
        .with => "intent.context",
    };
}

fn emitSelectedProbes(out: *trajectory.Console, profile: profile_mod.TestSet, name: []const u8) void {
    if (profile.intent) probe(out, name, "intent.resolve");
    if (profile.unit) probe(out, name, "tests.unit.actions");
    if (profile.integration) probe(out, name, "tests.integration");
    if (profile.e2e) probe(out, name, "tests.e2e.lightpanda");
    if (profile.semantic) probe(out, name, "tests.semantic");

    if (profile.data_write) data(out, name, "data.write");
    if (profile.data_read) data(out, name, "data.read");
    if (profile.data_cache) data(out, name, "data.cache");
    if (profile.data_search) data(out, name, "data.search");
    if (profile.data_vector) data(out, name, "data.vector");
    if (profile.data_graph) data(out, name, "data.graph");
    if (profile.data_events) data(out, name, "data.events");

    if (profile.benchmark) performance(out, name, "performance.benchmark");
    if (profile.load) performance(out, name, "performance.load");
    if (profile.stress) performance(out, name, "performance.stress");

    if (profile.discovery_graph) probe(out, name, "discovery.graph");
    if (profile.discovery_semantic) probe(out, name, "discovery.semantic");
}

fn probe(out: *trajectory.Console, trajectory_name: []const u8, name: []const u8) void {
    out.emit(.{
        .kind = .expansion,
        .trajectory = trajectory_name,
        .track = name,
        .name = "selected",
        .status = .observed,
    });
}

fn data(out: *trajectory.Console, trajectory_name: []const u8, name: []const u8) void {
    out.emit(.{
        .kind = .data_probe,
        .trajectory = trajectory_name,
        .track = name,
        .name = "selected",
        .status = .observed,
    });
}

fn performance(out: *trajectory.Console, trajectory_name: []const u8, name: []const u8) void {
    out.emit(.{
        .kind = .benchmark_sample,
        .trajectory = trajectory_name,
        .track = name,
        .name = "selected",
        .status = .observed,
    });
}
