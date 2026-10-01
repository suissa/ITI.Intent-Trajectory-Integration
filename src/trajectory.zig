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
};

test "trajectory event stream is ordered" {
    var console = Console{};
    console.emit(.{
        .kind = .trajectory_started,
        .trajectory = "login",
    });
    try std.testing.expectEqual(@as(usize, 1), console.sequence);
}
