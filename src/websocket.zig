const std = @import("std");
const Io = std.Io;
const http = std.http;
const trajectory = @import("trajectory.zig");

pub const event_capacity = 2_048;
const poll_interval_ms: i64 = 25;
const ping_interval_polls: usize = 600;

pub const BatchKind = enum {
    snapshot,
    replay,
};

pub const ReadBatch = struct {
    kind: BatchKind,
    sequence: usize,
    from_sequence: usize,
    events: []const trajectory.Event,
    truncated: bool,
};

pub const Hub = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    events: [event_capacity]trajectory.Event = undefined,
    start: usize = 0,
    len: usize = 0,
    sequence: usize = 0,
    session_id: [32]u8 = undefined,
    session_id_len: usize = 0,
    server_state: std.atomic.Value(u8) = .init(0),

    pub fn init(io: Io) Io.RandomSecureError!Hub {
        var random: [16]u8 = undefined;
        try Io.randomSecure(io, &random);

        var session: [32]u8 = undefined;
        const hex = "0123456789abcdef";
        for (random, 0..) |byte, index| {
            session[index * 2] = hex[byte >> 4];
            session[index * 2 + 1] = hex[byte & 0x0f];
        }
        return initWithSession(io, &session);
    }

    pub fn initWithSession(io: Io, session_id: []const u8) Hub {
        var hub = Hub{ .io = io };
        hub.session_id_len = @min(session_id.len, hub.session_id.len);
        @memcpy(hub.session_id[0..hub.session_id_len], session_id[0..hub.session_id_len]);
        return hub;
    }

    pub fn deinit(self: *Hub) void {
        _ = self;
    }

    pub fn sessionId(self: *const Hub) []const u8 {
        return self.session_id[0..self.session_id_len];
    }

    pub fn eventSink(self: *Hub) trajectory.EventSink {
        return .{
            .context = self,
            .emit_fn = emitFromContext,
        };
    }

    fn emitFromContext(context: *anyopaque, event: trajectory.Event) trajectory.Event {
        const self: *Hub = @ptrCast(@alignCast(context));
        return self.append(event);
    }

    pub fn append(self: *Hub, event: trajectory.Event) trajectory.Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.sequence += 1;
        var stored = event;
        stored.sequence = self.sequence;

        if (self.len < event_capacity) {
            const index = (self.start + self.len) % event_capacity;
            self.events[index] = stored;
            self.len += 1;
        } else {
            self.events[self.start] = stored;
            self.start = (self.start + 1) % event_capacity;
        }
        return stored;
    }

    pub fn readAfter(
        self: *Hub,
        after_sequence: usize,
        requested_session: []const u8,
        output: *[event_capacity]trajectory.Event,
    ) ReadBatch {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const oldest = if (self.len == 0)
            self.sequence + 1
        else
            self.events[self.start].sequence;
        const same_session = std.mem.eql(u8, requested_session, self.sessionId());
        const can_replay = same_session and
            after_sequence <= self.sequence and
            after_sequence >= oldest - 1;

        var count: usize = 0;
        if (can_replay) {
            for (0..self.len) |offset| {
                const event = self.events[(self.start + offset) % event_capacity];
                if (event.sequence <= after_sequence) continue;
                output[count] = event;
                count += 1;
            }
            return .{
                .kind = .replay,
                .sequence = self.sequence,
                .from_sequence = after_sequence + 1,
                .events = output[0..count],
                .truncated = false,
            };
        }

        for (0..self.len) |offset| {
            output[count] = self.events[(self.start + offset) % event_capacity];
            count += 1;
        }
        return .{
            .kind = .snapshot,
            .sequence = self.sequence,
            .from_sequence = oldest,
            .events = output[0..count],
            .truncated = self.sequence > self.len,
        };
    }

    pub fn markServerReady(self: *Hub) void {
        self.server_state.store(1, .release);
    }

    pub fn markServerFailed(self: *Hub) void {
        self.server_state.store(2, .release);
    }

    pub fn serverState(self: *const Hub) u8 {
        return self.server_state.load(.acquire);
    }
};

const SubscribeRequest = struct {
    after_sequence: usize = 0,
    session_id: [32]u8 = [_]u8{0} ** 32,
    session_id_len: usize = 0,
};

const SnapshotFrame = struct {
    protocol: []const u8 = "iti.trajectory",
    version: u8 = 1,
    kind: []const u8 = "snapshot",
    sessionId: []const u8,
    sequence: usize,
    truncated: bool,
    events: []const trajectory.Event,
};

const ReplayFrame = struct {
    protocol: []const u8 = "iti.trajectory",
    version: u8 = 1,
    kind: []const u8 = "replay",
    sessionId: []const u8,
    fromSequence: usize,
    toSequence: usize,
    events: []const trajectory.Event,
};

const EventFrame = struct {
    protocol: []const u8 = "iti.trajectory",
    version: u8 = 1,
    kind: []const u8 = "event",
    sessionId: []const u8,
    event: trajectory.Event,
};

fn parseSubscribe(allocator: std.mem.Allocator, bytes: []const u8) ?SubscribeRequest {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const type_value = object.get("type") orelse return null;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "subscribe")) {
        return null;
    }

    var request = SubscribeRequest{};
    if (object.get("afterSequence")) |value| {
        if (value != .integer or value.integer < 0) return null;
        request.after_sequence = @intCast(value.integer);
    }
    if (object.get("sessionId")) |value| {
        if (value != .string or value.string.len > request.session_id.len) return null;
        @memcpy(request.session_id[0..value.string.len], value.string);
        request.session_id_len = value.string.len;
    }
    return request;
}

fn sendJson(
    ws: *http.Server.WebSocket,
    allocator: std.mem.Allocator,
    value: anytype,
) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    try ws.writeMessage(json, .text);
}

fn sendBatch(
    ws: *http.Server.WebSocket,
    allocator: std.mem.Allocator,
    hub: *Hub,
    batch: ReadBatch,
) !void {
    switch (batch.kind) {
        .snapshot => try sendJson(ws, allocator, SnapshotFrame{
            .sessionId = hub.sessionId(),
            .sequence = batch.sequence,
            .truncated = batch.truncated,
            .events = batch.events,
        }),
        .replay => try sendJson(ws, allocator, ReplayFrame{
            .sessionId = hub.sessionId(),
            .fromSequence = batch.from_sequence,
            .toSequence = batch.sequence,
            .events = batch.events,
        }),
    }
}

fn handleConnection(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    hub: *Hub,
) void {
    var connection = stream;
    defer connection.close(io);

    var recv_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var reader = connection.reader(io, &recv_buffer);
    var writer = connection.writer(io, &send_buffer);
    var server: http.Server = .init(&reader.interface, &writer.interface);

    var request = server.receiveHead() catch return;
    const key = switch (request.upgradeRequested()) {
        .websocket => |value| value orelse return,
        else => {
            request.respond("expected a WebSocket upgrade\n", .{ .status = .bad_request }) catch {};
            return;
        },
    };

    var ws = request.respondWebSocket(.{ .key = key }) catch return;
    ws.flush() catch return;

    var subscribe: ?SubscribeRequest = null;
    while (subscribe == null) {
        const message = ws.readSmallMessage() catch |err| {
            if (err == error.ConnectionClose) ws.writeMessage("", .connection_close) catch {};
            return;
        };
        switch (message.opcode) {
            .ping => ws.writeMessage(message.data, .pong) catch return,
            .text => {
                subscribe = parseSubscribe(allocator, message.data);
                if (subscribe == null) {
                    ws.writeMessage("{\"error\":\"expected subscribe message\"}", .text) catch {};
                    return;
                }
            },
            .connection_close => {
                ws.writeMessage("", .connection_close) catch {};
                return;
            },
            else => {},
        }
    }

    var buffer: [event_capacity]trajectory.Event = undefined;
    const initial = hub.readAfter(
        subscribe.?.after_sequence,
        subscribe.?.session_id[0..subscribe.?.session_id_len],
        &buffer,
    );
    sendBatch(&ws, allocator, hub, initial) catch return;
    var last_sequence = initial.sequence;
    var poll_count: usize = 0;

    while (true) {
        io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch return;
        const batch = hub.readAfter(last_sequence, hub.sessionId(), &buffer);

        if (batch.kind == .snapshot) {
            sendBatch(&ws, allocator, hub, batch) catch return;
            last_sequence = batch.sequence;
        } else {
            for (batch.events) |event| {
                sendJson(&ws, allocator, EventFrame{
                    .sessionId = hub.sessionId(),
                    .event = event,
                }) catch return;
                last_sequence = event.sequence;
            }
        }

        poll_count += 1;
        if (poll_count % ping_interval_polls == 0) {
            ws.writeMessage("", .ping) catch return;
        }
    }
}

pub fn serve(
    io: Io,
    allocator: std.mem.Allocator,
    hub: *Hub,
    port: u16,
) Io.Cancelable!void {
    const address = Io.net.IpAddress.parse("127.0.0.1", port) catch {
        hub.markServerFailed();
        return error.Canceled;
    };
    var server = address.listen(io, .{ .reuse_address = true }) catch {
        hub.markServerFailed();
        return error.Canceled;
    };
    defer server.deinit(io);
    hub.markServerReady();

    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            continue;
        };
        group.concurrent(io, handleConnection, .{ io, allocator, stream, hub }) catch {
            var rejected = stream;
            rejected.close(io);
        };
    }
}

test "hub assigns one ordered sequence and returns initial snapshot" {
    var hub = Hub.initWithSession(std.testing.io, "test-session");
    var first = hub.append(.{
        .kind = .run_started,
        .trajectory = "test",
    });
    try std.testing.expectEqual(@as(usize, 1), first.sequence);

    first = hub.append(.{
        .kind = .trajectory_started,
        .trajectory = "test",
    });
    try std.testing.expectEqual(@as(usize, 2), first.sequence);

    var buffer: [event_capacity]trajectory.Event = undefined;
    const snapshot = hub.readAfter(0, "", &buffer);
    try std.testing.expectEqual(BatchKind.snapshot, snapshot.kind);
    try std.testing.expectEqual(@as(usize, 2), snapshot.sequence);
    try std.testing.expectEqual(@as(usize, 2), snapshot.events.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.events[0].sequence);
    try std.testing.expectEqual(@as(usize, 2), snapshot.events[1].sequence);
}

test "hub replays events only when session and cursor are valid" {
    var hub = Hub.initWithSession(std.testing.io, "test-session");
    _ = hub.append(.{ .kind = .run_started, .trajectory = "test" });
    _ = hub.append(.{ .kind = .track_started, .trajectory = "test", .track = "one" });
    _ = hub.append(.{ .kind = .track_finished, .trajectory = "test", .track = "one", .status = .passed });

    var buffer: [event_capacity]trajectory.Event = undefined;
    const replay = hub.readAfter(1, "test-session", &buffer);
    try std.testing.expectEqual(BatchKind.replay, replay.kind);
    try std.testing.expectEqual(@as(usize, 2), replay.events.len);
    try std.testing.expectEqual(@as(usize, 2), replay.events[0].sequence);

    const changed_session = hub.readAfter(1, "old-session", &buffer);
    try std.testing.expectEqual(BatchKind.snapshot, changed_session.kind);
}

test "slow subscriber is resynchronized when its cursor leaves the bounded event window" {
    var hub = Hub.initWithSession(std.testing.io, "test-session");
    for (0..event_capacity + 3) |_| {
        _ = hub.append(.{ .kind = .expansion, .trajectory = "test" });
    }

    var buffer: [event_capacity]trajectory.Event = undefined;
    const batch = hub.readAfter(0, "test-session", &buffer);
    try std.testing.expectEqual(BatchKind.snapshot, batch.kind);
    try std.testing.expect(batch.truncated);
    try std.testing.expectEqual(event_capacity, batch.events.len);
    try std.testing.expectEqual(@as(usize, event_capacity + 3), batch.sequence);
}

test "Console and WebSocket hub share the same sequence source" {
    var hub = Hub.initWithSession(std.testing.io, "test-session");
    var console = trajectory.Console{
        .projection = .ndjson,
        .sink = hub.eventSink(),
    };
    console.emit(.{ .kind = .run_started, .trajectory = "test" });
    console.emit(.{ .kind = .run_finished, .trajectory = "test", .status = .passed });

    var buffer: [event_capacity]trajectory.Event = undefined;
    const batch = hub.readAfter(0, "", &buffer);
    try std.testing.expectEqual(@as(usize, 2), console.sequence);
    try std.testing.expectEqual(@as(usize, 2), batch.sequence);
    try std.testing.expectEqual(batch.events[1].sequence, console.sequence);
}
