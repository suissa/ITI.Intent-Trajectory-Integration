const std = @import("std");
const dsl = @import("dsl.zig");
const profile_mod = @import("profile.zig");
const trajectory = @import("trajectory.zig");
const browser_mod = @import("browser.zig");
const data_plane = @import("data_plane.zig");

pub fn runParsed(
    comptime spec: anytype,
    comptime profile: profile_mod.TestSet,
    comptime projection: trajectory.Projection,
    comptime profile_name: []const u8,
    sink: ?trajectory.EventSink,
    semantic_context: trajectory.SemanticContext,
    browser: ?*browser_mod.Browser,
    data_plane_runtime: *data_plane.Runtime,
    io: std.Io,
) !void {
    var out = trajectory.Console{
        .projection = projection,
        .sink = sink,
        .semantic_context = semantic_context,
    };
    const trajectory_name = "iti.intent-trajectory";
    var run_failed = false;

    out.emit(.{
        .kind = .run_started,
        .trajectory = trajectory_name,
        .name = profile_name,
    });
    out.emit(.{
        .kind = .trajectory_started,
        .trajectory = trajectory_name,
        .name = profile_name,
    });

    inline for (spec.steps, 0..) |step, index| {
        const track_index = index + 1;
        const track = trackName(step.kind);
        var step_failed = false;
        var duration_ms: u64 = 0;
        out.emit(.{
            .kind = .track_started,
            .trajectory = trajectory_name,
            .track = track,
            .name = step.raw,
            .track_index = track_index,
        });
        if (browser) |runtime| {
            if (isBrowserStep(step.kind)) {
                duration_ms = runtime.execute(step) catch |err| blk: {
                    step_failed = true;
                    run_failed = true;
                    std.debug.print("ITI browser step failed: {s}: {s}\n", .{ step.raw, @errorName(err) });
                    break :blk 0;
                };
            }
        }

        if (step.kind == .hope or step.kind == .hope_see) {
            out.emit(.{
                .kind = if (step_failed) .assertion_failed else .assertion_passed,
                .trajectory = trajectory_name,
                .track = track,
                .name = step.object,
                .status = if (step_failed) .failed else .passed,
                .track_index = track_index,
            });
        } else {
            out.emit(.{
                .kind = if (step_failed) .assertion_failed else .expansion,
                .trajectory = trajectory_name,
                .track = track,
                .name = step.raw,
                .status = if (step_failed) .failed else .observed,
                .track_index = track_index,
            });
        }

        out.emit(.{
            .kind = .track_finished,
            .trajectory = trajectory_name,
            .track = track,
            .status = if (step_failed) .failed else .passed,
            .track_index = track_index,
        });
        if (browser != null and isBrowserStep(step.kind)) {
            var timing_buffer: [64]u8 = undefined;
            const timing = std.fmt.bufPrint(&timing_buffer, "duration_ms={d}", .{duration_ms}) catch "duration_ms=0";
            out.emit(.{
                .kind = .benchmark_sample,
                .trajectory = trajectory_name,
                .track = track,
                .name = timing,
                .status = .observed,
                .track_index = track_index,
            });
        }
    }

    run_failed = emitSelectedProbes(&out, profile, trajectory_name, data_plane_runtime, io, semantic_context) or run_failed;

    out.emit(.{
        .kind = .trajectory_finished,
        .trajectory = trajectory_name,
        .status = if (run_failed) .failed else .passed,
    });
    out.emit(.{
        .kind = .run_finished,
        .trajectory = trajectory_name,
        .status = if (run_failed) .failed else .passed,
    });
    if (run_failed) return error.BrowserExecutionFailed;
}

fn isBrowserStep(kind: dsl.StepKind) bool {
    return switch (kind) {
        .open, .type_into, .click, .hope_see => true,
        else => false,
    };
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

fn emitSelectedProbes(
    out: *trajectory.Console,
    profile: profile_mod.TestSet,
    name: []const u8,
    runtime: *data_plane.Runtime,
    io: std.Io,
    semantic: trajectory.SemanticContext,
) bool {
    var failed = false;
    if (profile.intent) probe(out, name, "intent.resolve");
    if (profile.unit) probe(out, name, "tests.unit.actions");
    if (profile.integration) probe(out, name, "tests.integration");
    if (profile.e2e) probe(out, name, "tests.e2e.lightpanda");
    if (profile.semantic) probe(out, name, "tests.semantic");

    const context = data_plane.ProbeContext{
        .correlation_id = semantic.correlation_id,
        .causation_id = semantic.causation_id,
        .actor_type = semantic.actor_type,
        .subject_id = semantic.subject_id,
        .intent_id = semantic.intent_id,
        .behavior_id = semantic.behavior_id,
        .action_id = semantic.action_id,
    };
    if (profile.data_write) failed = data(out, name, "data.write", .write, runtime, io, context) or failed;
    if (profile.data_read) failed = data(out, name, "data.read", .read, runtime, io, context) or failed;
    if (profile.data_cache) failed = data(out, name, "data.cache", .cache, runtime, io, context) or failed;
    if (profile.data_search) failed = data(out, name, "data.search", .search, runtime, io, context) or failed;
    if (profile.data_vector) failed = data(out, name, "data.vector", .vector, runtime, io, context) or failed;
    if (profile.data_graph) failed = data(out, name, "data.graph", .graph, runtime, io, context) or failed;
    if (profile.data_events) failed = data(out, name, "data.events", .events, runtime, io, context) or failed;

    if (profile.benchmark) performance(out, name, "performance.benchmark");
    if (profile.load) performance(out, name, "performance.load");
    if (profile.stress) performance(out, name, "performance.stress");

    if (profile.discovery_graph) probe(out, name, "discovery.graph");
    if (profile.discovery_semantic) probe(out, name, "discovery.semantic");
    return failed;
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

fn data(
    out: *trajectory.Console,
    trajectory_name: []const u8,
    track: []const u8,
    capability: data_plane.Capability,
    runtime: *data_plane.Runtime,
    io: std.Io,
    context: data_plane.ProbeContext,
) bool {
    const outcomes = runtime.registry.probeAll(capability, io, context) catch |err| {
        out.emit(.{
            .kind = .data_probe,
            .trajectory = trajectory_name,
            .track = track,
            .name = @errorName(err),
            .status = .failed,
        });
        return true;
    };
    defer runtime.registry.allocator.free(outcomes);

    if (outcomes.len == 0) {
        const configured = runtime.registry.adapters.items.len > 0;
        out.emit(.{
            .kind = .data_probe,
            .trajectory = trajectory_name,
            .track = track,
            .name = if (configured) "no-adapter-supports-capability" else "no-adapter-configured",
            .status = if (configured) .failed else .observed,
        });
        return configured;
    }

    var failed = false;
    for (outcomes) |outcome| {
        const status: trajectory.Status = switch (outcome.result.status) {
            .passed => .passed,
            .failed => .failed,
            .skipped => .observed,
        };
        out.emit(.{
            .kind = .data_probe,
            .trajectory = trajectory_name,
            .track = track,
            .name = outcome.adapter_id,
            .status = status,
        });

        var timing_buffer: [64]u8 = undefined;
        const timing = std.fmt.bufPrint(&timing_buffer, "duration_ms={d}", .{outcome.result.duration_ms}) catch "duration_ms=0";
        out.emit(.{
            .kind = .benchmark_sample,
            .trajectory = trajectory_name,
            .track = track,
            .name = timing,
            .status = .observed,
        });
        if (outcome.result.status == .failed) failed = true;
    }
    return failed;
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
