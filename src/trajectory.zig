const std = @import("std");

pub const EventKind = enum {
    run_started,
    run_finished,
    trajectory_started,
    trajectory_finished,
    track_started,
    track_finished,
    expansion,
    assertion_passed,
    assertion_failed,
    benchmark_sample,
    data_probe,
};

pub const Status = enum {
    running,
    passed,
    failed,
    observed,
};

pub const Projection = enum {
    ndjson,
    tui,

    pub fn fromName(comptime name: []const u8) Projection {
        if (std.mem.eql(u8, name, "ndjson")) return .ndjson;
        if (std.mem.eql(u8, name, "tui")) return .tui;
        @compileError("ITI: unknown UI projection: " ++ name);
    }
};

pub const Event = struct {
    kind: EventKind,
    trajectory: []const u8,
    track: []const u8 = "",
    name: []const u8 = "",
    status: Status = .running,
    sequence: usize = 0,
};

pub const Console = struct {
    sequence: usize = 0,
    projection: Projection = .ndjson,

    pub fn emit(self: *Console, event: Event) void {
        self.sequence += 1;
        const e = Event{
            .kind = event.kind,
            .trajectory = event.trajectory,
            .track = event.track,
            .name = event.name,
            .status = event.status,
            .sequence = self.sequence,
        };

        switch (self.projection) {
            .ndjson => emitNdjson(e),
            .tui => emitTui(e),
        }
    }
};

fn emitNdjson(e: Event) void {
    std.debug.print(
        "{{\"sequence\":{d},\"kind\":\"{s}\",\"trajectory\":\"{s}\",\"track\":\"{s}\",\"name\":\"{s}\",\"status\":\"{s}\"}}\n",
        .{
            e.sequence,
            @tagName(e.kind),
            e.trajectory,
            e.track,
            e.name,
            @tagName(e.status),
        },
    );
}

fn emitTui(e: Event) void {
    const mark = switch (e.status) {
        .passed => "✓",
        .failed => "✗",
        .running => "●",
        .observed => "↳",
    };

    switch (e.kind) {
        .run_started => std.debug.print("┌─ ITI · {s} · {s}\n", .{ e.trajectory, e.name }),
        .run_finished => std.debug.print("└─ {s} RUN {s}\n", .{ mark, @tagName(e.status) }),
        .trajectory_started => std.debug.print("   ● TRAJECTORY {s}\n", .{e.trajectory}),
        .trajectory_finished => std.debug.print("   {s} TRAJECTORY {s}\n", .{ mark, @tagName(e.status) }),
        .track_started => std.debug.print("   ▶ {s}\n", .{e.track}),
        .track_finished => std.debug.print("   {s} {s}\n", .{ mark, e.track }),
        .expansion => std.debug.print("      ↳ {s}\n", .{e.name}),
        .assertion_passed, .assertion_failed => std.debug.print("      {s} ASSERT {s}\n", .{ mark, e.name }),
        .benchmark_sample => std.debug.print("      ◇ {s}\n", .{e.track}),
        .data_probe => std.debug.print("      ◆ {s}\n", .{e.track}),
    }
}

test "trajectory console starts with an empty sequence" {
    const console = Console{ .projection = .ndjson };
    try std.testing.expectEqual(@as(usize, 0), console.sequence);
}
