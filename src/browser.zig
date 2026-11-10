const std = @import("std");
const dsl = @import("dsl.zig");
const cdp = @import("cdp.zig");

pub const Browser = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    client: cdp.Client,

    pub fn connectOrStart(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
    ) !Browser {
        if (cdp.Client.connect(allocator, io)) |client| {
            return .{ .allocator = allocator, .io = io, .environ = environ, .client = client };
        } else |_| {}

        try startLightpanda(allocator, io);
        for (0..50) |_| {
            try io.sleep(.fromMilliseconds(100), .awake);
            if (cdp.Client.connect(allocator, io)) |client| {
                return .{ .allocator = allocator, .io = io, .environ = environ, .client = client };
            } else |_| {}
        }
        return error.LightpandaNotReady;
    }

    pub fn deinit(self: *Browser) void {
        self.client.deinit();
    }

    /// Execute one browser DSL step and return its wall-clock duration in ms.
    pub fn execute(self: *Browser, step: dsl.Step) !u64 {
        const started = std.Io.Clock.awake.now(self.io).nanoseconds;
        switch (step.kind) {
            .open => {
                const url = try self.resolveUrl(step.object);
                defer self.allocator.free(url);
                try self.client.open(url);
            },
            .type_into => {
                const value = try self.resolveValue(step.value);
                defer self.allocator.free(value);
                try self.client.typeInto(value, step.object);
            },
            .click => try self.client.click(step.object),
            .hope_see => try self.client.hopeSee(step.object),
            else => return 0,
        }
        const ended = std.Io.Clock.awake.now(self.io).nanoseconds;
        return if (ended > started)
            @intCast(@divTrunc(ended - started, 1_000_000))
        else
            0;
    }

    fn resolveUrl(self: *Browser, target: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "data:")) {
            return self.allocator.dupe(u8, target);
        }
        const base = self.environ.get("ITI_BASE_URL") orelse return error.MissingBaseUrl;
        const separator = if (std.mem.endsWith(u8, base, "/")) "" else "/";
        return std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ base, separator, target });
    }

    fn resolveValue(self: *Browser, raw: []const u8) ![]const u8 {
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
            return self.allocator.dupe(u8, raw[1 .. raw.len - 1]);
        }
        if (!std.mem.startsWith(u8, raw, "$")) return self.allocator.dupe(u8, raw);

        const name = raw[1..];
        const key = try environmentKey(self.allocator, name);
        defer self.allocator.free(key);
        const value = self.environ.get(key) orelse return error.MissingActorValue;
        return self.allocator.dupe(u8, value);
    }
};

fn startLightpanda(allocator: std.mem.Allocator, io: std.Io) !void {
    const command =
        "command -v lightpanda >/dev/null 2>&1 || exit 127; " ++
        "(LIGHTPANDA_DISABLE_TELEMETRY=true nohup lightpanda serve --host 127.0.0.1 --port 9222 " ++
        ">\"${TMPDIR:-/tmp}/iti-lightpanda.log\" 2>&1 </dev/null &)";
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.LightpandaExecutableNotFound,
        else => return error.LightpandaStartFailed,
    }
}

fn environmentKey(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const key = try allocator.alloc(u8, 4 + name.len);
    @memcpy(key[0..4], "ITI_");
    for (name, 0..) |char, index| {
        key[index + 4] = switch (char) {
            '.', '-', ' ' => '_',
            else => std.ascii.toUpper(char),
        };
    }
    return key;
}

test "actor variable names map to explicit ITI environment keys" {
    const key = try environmentKey(std.testing.allocator, "customer.email");
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("ITI_CUSTOMER_EMAIL", key);
}

test "environment key conversion is deterministic" {
    const key = try environmentKey(std.testing.allocator, "order-id");
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("ITI_ORDER_ID", key);
}
