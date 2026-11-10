const std = @import("std");
const Io = std.Io;
const trajectory = @import("trajectory.zig");

const max_tracks = 256;
const max_expansions_per_track = 64;
const max_relations = 512;

const OtdAttributes = struct {
    correlationId: ?[]const u8 = null,
    causationId: ?[]const u8 = null,
    actorType: ?[]const u8 = null,
    subjectId: ?[]const u8 = null,
    intentId: ?[]const u8 = null,
    behaviorId: ?[]const u8 = null,
    actionId: ?[]const u8 = null,
};

const OtdExpansion = struct {
    id: []const u8,
    label: []const u8,
    timestamp: []const u8,
    offsetMs: u64,
    attributes: OtdAttributes,
};

const OtdError = struct {
    name: []const u8,
    message: []const u8,
};

const OtdTrackSnapshot = struct {
    id: []const u8,
    trajectoryId: []const u8,
    parentId: ?[]const u8 = null,
    name: []const u8,
    startedAt: []const u8,
    endedAt: ?[]const u8 = null,
    durationMs: ?u64 = null,
    status: []const u8,
    depth: usize,
    sequence: usize,
    attributes: OtdAttributes,
    expansions: []const OtdExpansion,
    error: ?OtdError = null,
};

const OtdRelation = struct {
    fromTrackId: []const u8,
    toTrackId: []const u8,
    kind: []const u8,
    attributes: OtdAttributes,
};

pub const Destination = struct {
    id: []const u8,
    label: []const u8,
    status: []const u8,
    attributes: OtdAttributes,
};

const OtdTrajectorySnapshot = struct {
    id: []const u8,
    name: []const u8,
    correlationId: []const u8,
    startedAt: []const u8,
    endedAt: ?[]const u8 = null,
    durationMs: ?u64 = null,
    processUptimeMs: u64,
    processStartupMs: u64,
    status: []const u8,
    attributes: OtdAttributes,
    tracks: []const OtdTrackSnapshot,
    relations: []const OtdRelation,
    destination: ?Destination = null,
};

const TrackState = struct {
    id: []const u8,
    name: []const u8,
    parent_id: ?[]const u8 = null,
    started_at: []const u8,
    ended_at: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    status: []const u8 = "running",
    depth: usize = 0,
    sequence: usize,
    started_ns: u64,
    attributes: OtdAttributes,
    expansions: std.ArrayListUnmanaged(OtdExpansion) = .empty,
    failure: ?OtdError = null,

    fn snapshot(self: *const TrackState, trajectory_id: []const u8) OtdTrackSnapshot {
        return .{
            .id = self.id,
            .trajectoryId = trajectory_id,
            .parentId = self.parent_id,
            .name = self.name,
            .startedAt = self.started_at,
            .endedAt = self.ended_at,
            .durationMs = self.duration_ms,
            .status = self.status,
            .depth = self.depth,
            .sequence = self.sequence,
            .attributes = self.attributes,
            .expansions = self.expansions.items,
            .error = self.failure,
        };
    }
};

pub const Exporter = struct {
    arena: std.heap.ArenaAllocator,
    io: Io,
    session_id: []const u8,
    enabled: bool,
    process_started_ns: u64,
    sequence: usize = 0,
    trajectory_id: []const u8 = "",
    trajectory_name: []const u8 = "",
    trajectory_started_at: []const u8 = "",
    trajectory_started_ns: u64 = 0,
    trajectory_ended_at: ?[]const u8 = null,
    trajectory_duration_ms: ?u64 = null,
    trajectory_status: []const u8 = "running",
    semantic: trajectory.SemanticContext = .{},
    tracks: std.ArrayListUnmanaged(TrackState) = .empty,
    relations: std.ArrayListUnmanaged(OtdRelation) = .empty,
    snapshot_tracks: std.ArrayListUnmanaged(OtdTrackSnapshot) = .empty,
    destination: ?Destination = null,
    last_track_index: usize = 0,
    last_action_index: usize = 0,
    last_intent_index: usize = 0,

    pub fn init(
        parent_allocator: std.mem.Allocator,
        io: Io,
        session_id: []const u8,
        enabled: bool,
        semantic: trajectory.SemanticContext,
    ) !Exporter {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const owned_session = try allocator.dupe(u8, session_id);
        return .{
            .arena = arena,
            .io = io,
            .session_id = owned_session,
            .enabled = enabled,
            .process_started_ns = nowNs(io),
            .semantic = semantic,
        };
    }

    pub fn deinit(self: *Exporter) void {
        self.arena.deinit();
    }

    fn allocator(self: *Exporter) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn eventSink(self: *Exporter) trajectory.EventSink {
        return .{ .context = self, .emit_fn = emitFromContext };
    }

    fn emitFromContext(context: *anyopaque, event: trajectory.Event) trajectory.Event {
        const self: *Exporter = @ptrCast(@alignCast(context));
        return self.emit(event);
    }

    pub fn emit(self: *Exporter, event: trajectory.Event) trajectory.Event {
        if (!self.enabled) return event;
        switch (event.kind) {
            .trajectory_started => self.startTrajectory(event) catch self.reportError("trajectory.started"),
            .track_started => self.startTrack(event) catch self.reportError("track.started"),
            .expansion => self.recordExpansion(event) catch self.reportError("expansion.recorded"),
            .assertion_passed, .assertion_failed => self.recordDestination(event) catch self.reportError("destination"),
            .data_probe, .benchmark_sample => self.recordProbe(event) catch self.reportError("probe"),
            .track_finished => self.finishTrack(event) catch self.reportError("track.ended"),
            .trajectory_finished => self.finishTrajectory(event) catch self.reportError("trajectory.ended"),
            .run_started, .run_finished => {},
        }
        return event;
    }

    fn startTrajectory(self: *Exporter, event: trajectory.Event) !void {
        self.trajectory_id = event.trajectory;
        self.trajectory_name = if (event.name.len > 0) event.name else event.trajectory;
        self.trajectory_started_at = try timestamp(self.allocator());
        self.trajectory_started_ns = nowNs(self.io);
        self.trajectory_status = "running";
        try self.writeEvent("trajectory.started", self.snapshot());
    }

    fn startTrack(self: *Exporter, event: trajectory.Event) !void {
        const index = if (event.track_index > 0) event.track_index else self.tracks.items.len + 1;
        const previous = self.last_track_index;
        const track = try self.ensureTrack(index, event);
        track.name = event.track;
        track.parent_id = if (event.parent_track_index > 0)
            (try self.ensureTrack(event.parent_track_index, event)).id
        else
            null;
        track.depth = if (event.parent_track_index > 0) 1 else 0;
        const semantic = self.effectiveSemantic(event.semantic);
        track.attributes = self.attributes(semantic, index, event.track);
        try self.writeEvent("track.started", track.snapshot(self.trajectory_id));

        if (previous > 0 and previous != index) {
            try self.addRelation(previous, index, "follows", event.semantic);
        }
        if (std.mem.eql(u8, event.track, "intent.wish")) {
            self.last_intent_index = index;
        } else if (std.mem.startsWith(u8, event.track, "browser.")) {
            if (self.last_intent_index > 0) {
                try self.addRelation(self.last_intent_index, index, "causes", event.semantic);
            }
            if (self.last_action_index > 0) {
                try self.addRelation(self.last_action_index, index, "depends_on", event.semantic);
            }
            self.last_action_index = index;
        } else if (std.mem.eql(u8, event.track, "intent.context") and previous > 0) {
            try self.addRelation(previous, index, "expands", event.semantic);
        } else if (std.mem.startsWith(u8, event.track, "assertion.") and self.last_action_index > 0) {
            try self.addRelation(self.last_action_index, index, "derives_from", event.semantic);
        }
        self.last_track_index = index;
    }

    fn recordExpansion(self: *Exporter, event: trajectory.Event) !void {
        const index = if (event.track_index > 0) event.track_index else self.tracks.items.len;
        if (index == 0) return;
        const track = try self.ensureTrack(index, event);
        const item = try self.appendExpansion(track, event.name, self.effectiveSemantic(event.semantic));
        const payload = .{
            .track = track.snapshot(self.trajectory_id),
            .expansion = item,
        };
        try self.writeEvent("expansion.recorded", payload);
    }

    fn recordDestination(self: *Exporter, event: trajectory.Event) !void {
        const index = if (event.track_index > 0) event.track_index else self.tracks.items.len;
        if (index == 0) return;
        const track = try self.ensureTrack(index, event);
        const semantic = self.effectiveSemantic(event.semantic);
        const expansion = try self.appendExpansion(track, event.name, semantic);
        const id = try std.fmt.allocPrint(self.allocator(), "destination-{d}", .{index});
        self.destination = .{
            .id = id,
            .label = event.name,
            .status = if (event.status == .failed) "failed" else "satisfied",
            .attributes = self.attributes(semantic, index, event.track),
        };
        const payload = .{
            .track = track.snapshot(self.trajectory_id),
            .expansion = expansion,
        };
        try self.writeEvent("expansion.recorded", payload);
    }

    fn recordProbe(self: *Exporter, event: trajectory.Event) !void {
        const index = if (event.track_index > 0) event.track_index else self.tracks.items.len + 1;
        const is_new = index > self.tracks.items.len;
        const track = try self.ensureTrack(index, event);
        if (is_new) {
            track.name = event.track;
            track.status = "running";
            try self.writeEvent("track.started", track.snapshot(self.trajectory_id));
            if (self.last_track_index > 0) {
                try self.addRelation(self.last_track_index, index, "follows", event.semantic);
            }
            self.last_track_index = index;
        }
        const semantic = self.effectiveSemantic(event.semantic);
        const expansion = try self.appendExpansion(track, event.name, semantic);
        const payload = .{ .track = track.snapshot(self.trajectory_id), .expansion = expansion };
        try self.writeEvent("expansion.recorded", payload);
    }

    fn finishTrack(self: *Exporter, event: trajectory.Event) !void {
        const index = if (event.track_index > 0) event.track_index else self.tracks.items.len;
        if (index == 0) return;
        const track = try self.ensureTrack(index, event);
        const ended_at = try timestamp(self.allocator());
        const now = nowNs(self.io);
        track.ended_at = ended_at;
        track.duration_ms = if (now >= track.started_ns) (now - track.started_ns) / 1_000_000 else 0;
        track.status = if (event.status == .failed) "error" else "ok";
        if (event.status == .failed) {
            track.failure = .{ .name = "AssertionError", .message = event.name };
            try self.writeEvent("track.failed", track.snapshot(self.trajectory_id));
        }
        try self.writeEvent("track.ended", track.snapshot(self.trajectory_id));
    }

    fn finishTrajectory(self: *Exporter, event: trajectory.Event) !void {
        const ended_at = try timestamp(self.allocator());
        const now = nowNs(self.io);
        self.trajectory_ended_at = ended_at;
        self.trajectory_duration_ms = if (now >= self.trajectory_started_ns)
            (now - self.trajectory_started_ns) / 1_000_000
        else
            0;
        self.trajectory_status = if (event.status == .failed) "error" else "ok";
        if (event.status == .failed) try self.writeEvent("trajectory.failed", self.snapshot());
        try self.writeEvent("trajectory.ended", self.snapshot());
    }

    fn ensureTrack(self: *Exporter, index: usize, event: trajectory.Event) !*TrackState {
        if (index == 0 or index > max_tracks) return error.TrackLimitExceeded;
        while (self.tracks.items.len < index) {
            const next_index = self.tracks.items.len + 1;
            const id = try std.fmt.allocPrint(self.allocator(), "iti-track-{d}", .{next_index});
            const started_at = try timestamp(self.allocator());
            try self.tracks.append(self.allocator(), .{
                .id = id,
                .name = if (next_index == index) event.track else "unobserved",
                .started_at = started_at,
                .sequence = next_index,
                .started_ns = nowNs(self.io),
                .attributes = self.attributes(self.effectiveSemantic(event.semantic), next_index, event.track),
            });
        }
        return &self.tracks.items[index - 1];
    }

    fn appendExpansion(
        self: *Exporter,
        track: *TrackState,
        label: []const u8,
        semantic: trajectory.SemanticContext,
    ) !OtdExpansion {
        if (track.expansions.items.len >= max_expansions_per_track) return error.ExpansionLimitExceeded;
        const index = track.expansions.items.len + 1;
        const id = try std.fmt.allocPrint(self.allocator(), "iti-expansion-{d}-{d}", .{ track.sequence, index });
        const item = OtdExpansion{
            .id = id,
            .label = label,
            .timestamp = try timestamp(self.allocator()),
            .offsetMs = blk: {
                const now = nowNs(self.io);
                break :blk if (now >= track.started_ns) (now - track.started_ns) / 1_000_000 else 0;
            },
            .attributes = self.attributes(semantic, track.sequence, track.name),
        };
        try track.expansions.append(self.allocator(), item);
        return item;
    }

    fn addRelation(
        self: *Exporter,
        from_index: usize,
        to_index: usize,
        kind: []const u8,
        semantic: trajectory.SemanticContext,
    ) !void {
        if (self.relations.items.len >= max_relations) return error.RelationLimitExceeded;
        if (from_index == 0 or to_index == 0 or from_index > self.tracks.items.len or to_index > self.tracks.items.len) return;
        const relation = OtdRelation{
            .fromTrackId = self.tracks.items[from_index - 1].id,
            .toTrackId = self.tracks.items[to_index - 1].id,
            .kind = kind,
            .attributes = self.attributes(self.effectiveSemantic(semantic), to_index, self.tracks.items[to_index - 1].name),
        };
        try self.relations.append(self.allocator(), relation);
        try self.writeEvent("relation.recorded", relation);
    }

    fn effectiveSemantic(self: *Exporter, event: trajectory.SemanticContext) trajectory.SemanticContext {
        return .{
            .correlation_id = if (event.correlation_id.len > 0) event.correlation_id else self.semantic.correlation_id,
            .causation_id = if (event.causation_id.len > 0) event.causation_id else self.semantic.causation_id,
            .actor_type = if (event.actor_type.len > 0) event.actor_type else self.semantic.actor_type,
            .subject_id = if (event.subject_id.len > 0) event.subject_id else self.semantic.subject_id,
            .intent_id = if (event.intent_id.len > 0) event.intent_id else self.semantic.intent_id,
            .behavior_id = if (event.behavior_id.len > 0) event.behavior_id else self.semantic.behavior_id,
            .action_id = if (event.action_id.len > 0) event.action_id else self.semantic.action_id,
        };
    }

    fn attributes(self: *Exporter, semantic: trajectory.SemanticContext, index: usize, track_name: []const u8) OtdAttributes {
        const action_id = if (semantic.action_id.len > 0)
            semantic.action_id
        else if (index > 0 and std.mem.startsWith(u8, track_name, "browser."))
            std.fmt.allocPrint(self.allocator(), "action-{d}", .{index}) catch ""
        else
            "";
        const causation_id = if (semantic.causation_id.len > 0)
            semantic.causation_id
        else if (index > 1 and index - 1 <= self.tracks.items.len)
            self.tracks.items[index - 2].id
        else
            "";
        return .{
            .correlationId = if (semantic.correlation_id.len > 0) semantic.correlation_id else self.session_id,
            .causationId = if (causation_id.len > 0) causation_id else null,
            .actorType = if (semantic.actor_type.len > 0) semantic.actor_type else null,
            .subjectId = if (semantic.subject_id.len > 0) semantic.subject_id else null,
            .intentId = if (semantic.intent_id.len > 0) semantic.intent_id else null,
            .behaviorId = if (semantic.behavior_id.len > 0) semantic.behavior_id else null,
            .actionId = if (action_id.len > 0) action_id else null,
        };
    }

    fn snapshot(self: *Exporter) OtdTrajectorySnapshot {
        self.snapshot_tracks.clearRetainingCapacity();
        for (self.tracks.items) |*track| {
            self.snapshot_tracks.append(self.allocator(), track.snapshot(self.trajectory_id)) catch {};
        }
        const now = nowNs(self.io);
        const uptime = if (now >= self.process_started_ns) (now - self.process_started_ns) / 1_000_000 else 0;
        return .{
            .id = self.trajectory_id,
            .name = self.trajectory_name,
            .correlationId = self.session_id,
            .startedAt = self.trajectory_started_at,
            .endedAt = self.trajectory_ended_at,
            .durationMs = self.trajectory_duration_ms,
            .processUptimeMs = uptime,
            .processStartupMs = uptime,
            .status = self.trajectory_status,
            .attributes = self.attributes(self.semantic, 0, ""),
            .tracks = self.snapshot_tracks.items,
            .relations = self.relations.items,
            .destination = self.destination,
        };
    }

    fn writeEvent(self: *Exporter, comptime Payload: type, event_type: []const u8, payload: Payload) !void {
        self.sequence += 1;
        const event_timestamp = try timestamp(self.allocator());
        const Envelope = struct {
            protocol: []const u8 = "open-trajectory",
            version: u8 = 1,
            sessionId: []const u8,
            sequence: usize,
            timestamp: []const u8,
            trajectoryId: []const u8,
            type: []const u8,
            payload: Payload,
        };
        const envelope = Envelope{
            .sessionId = self.session_id,
            .sequence = self.sequence,
            .timestamp = event_timestamp,
            .trajectoryId = self.trajectory_id,
            .type = event_type,
            .payload = payload,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator(), envelope, .{});
        std.debug.print("{s}\n", .{json});
    }

    fn reportError(self: *Exporter, stage: []const u8) void {
        _ = self;
        std.debug.print("OpenTrajectory exporter failed at {s}\n", .{stage});
    }
};

fn nowNs(io: Io) u64 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn timestamp(allocator: std.mem.Allocator) ![]const u8 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    const days = @divFloor(ts.sec, 86_400);
    const seconds = @mod(ts.sec, 86_400);
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1_460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    year += if (month <= 2) 1 else 0;
    const hour = @divTrunc(seconds, 3_600);
    const minute = @divTrunc(@mod(seconds, 3_600), 60);
    const second = @mod(seconds, 60);
    const millis = @divTrunc(ts.nsec, 1_000_000);
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{ year, month, day, hour, minute, second, millis },
    );
}

test "OpenTrajectory exporter preserves protocol identity and emits all relation kinds" {
    var exporter = try Exporter.init(
        std.testing.allocator,
        std.testing.io,
        "session-test",
        true,
        .{
            .correlation_id = "correlation-test",
            .actor_type = "Human",
            .subject_id = "$customer",
            .intent_id = "intent-checkout",
            .behavior_id = "behavior-purchase",
        },
    );
    defer exporter.deinit();

    _ = exporter.emit(.{ .kind = .trajectory_started, .trajectory = "iti.intent-trajectory", .sequence = 1 });
    _ = exporter.emit(.{ .kind = .track_started, .trajectory = "iti.intent-trajectory", .track = "intent.wish", .track_index = 1, .sequence = 2 });
    _ = exporter.emit(.{ .kind = .track_started, .trajectory = "iti.intent-trajectory", .track = "browser.open", .track_index = 2, .sequence = 3 });
    _ = exporter.emit(.{ .kind = .track_started, .trajectory = "iti.intent-trajectory", .track = "browser.click", .track_index = 3, .sequence = 4 });
    _ = exporter.emit(.{ .kind = .track_started, .trajectory = "iti.intent-trajectory", .track = "intent.context", .track_index = 4, .sequence = 5 });
    _ = exporter.emit(.{ .kind = .track_started, .trajectory = "iti.intent-trajectory", .track = "assertion.see", .track_index = 5, .sequence = 6 });

    try std.testing.expectEqual(@as(usize, 5), exporter.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 9), exporter.relations.items.len);
    try std.testing.expectEqualStrings("session-test", exporter.session_id);
    try std.testing.expectEqualStrings("correlation-test", exporter.semantic.correlation_id);
    try std.testing.expectEqualStrings("Human", exporter.tracks.items[0].attributes.actorType.?);
    try std.testing.expectEqualStrings("$customer", exporter.tracks.items[0].attributes.subjectId.?);
    try std.testing.expectEqualStrings("behavior-purchase", exporter.tracks.items[1].attributes.behaviorId.?);
}
