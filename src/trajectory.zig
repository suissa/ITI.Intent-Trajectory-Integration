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

pub const SemanticContext = struct {
    correlation_id: []const u8 = "",
    causation_id: []const u8 = "",
    actor_type: []const u8 = "",
    subject_id: []const u8 = "",
    intent_id: []const u8 = "",
    behavior_id: []const u8 = "",
    action_id: []const u8 = "",
};

pub const Event = struct {
    kind: EventKind,
    trajectory: []const u8,
    track: []const u8 = "",
    name: []const u8 = "",
    status: Status = .running,
    sequence: usize = 0,
    track_index: usize = 0,
    parent_track_index: usize = 0,
    semantic: SemanticContext = .{},
};

pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: Event) Event,

    pub fn emit(self: EventSink, event: Event) Event {
        return self.emit_fn(self.context, event);
    }
};

pub const EventFanout = struct {
    first: EventSink,
    second: EventSink,

    pub fn eventSink(self: *EventFanout) EventSink {
        return .{ .context = self, .emit_fn = emitFromContext };
    }

    fn emitFromContext(context: *anyopaque, event: Event) Event {
        const self: *EventFanout = @ptrCast(@alignCast(context));
        const first = self.first.emit(event);
        return self.second.emit(first);
    }
};

pub const Console = struct {
    sequence: usize = 0,
    projection: Projection = .ndjson,
    sink: ?EventSink = null,
    semantic_context: SemanticContext = .{},

    pub fn emit(self: *Console, event: Event) void {
        self.sequence += 1;
        var e = event;
        e.sequence = self.sequence;
        e.semantic = mergeSemantic(self.semantic_context, event.semantic);
        if (self.sink) |sink| {
            e = sink.emit(e);
            self.sequence = e.sequence;
        }

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

fn mergeSemantic(base: SemanticContext, event: SemanticContext) SemanticContext {
    return .{
        .correlation_id = if (event.correlation_id.len > 0) event.correlation_id else base.correlation_id,
        .causation_id = if (event.causation_id.len > 0) event.causation_id else base.causation_id,
        .actor_type = if (event.actor_type.len > 0) event.actor_type else base.actor_type,
        .subject_id = if (event.subject_id.len > 0) event.subject_id else base.subject_id,
        .intent_id = if (event.intent_id.len > 0) event.intent_id else base.intent_id,
        .behavior_id = if (event.behavior_id.len > 0) event.behavior_id else base.behavior_id,
        .action_id = if (event.action_id.len > 0) event.action_id else base.action_id,
    };
}
