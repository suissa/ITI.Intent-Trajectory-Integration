const std = @import("std");

pub const TestSet = struct {
    intent: bool = false,
    unit: bool = false,
    integration: bool = false,
    e2e: bool = false,
    semantic: bool = false,

    data_write: bool = false,
    data_read: bool = false,
    data_cache: bool = false,
    data_search: bool = false,
    data_vector: bool = false,
    data_graph: bool = false,
    data_events: bool = false,

    benchmark: bool = false,
    load: bool = false,
    stress: bool = false,

    trace: bool = true,
    discovery_graph: bool = false,
    discovery_semantic: bool = false,
};

pub fn fromName(comptime name: []const u8) TestSet {
    if (std.mem.eql(u8, name, "minimal")) return .{
        .intent = true,
        .trace = true,
    };

    if (std.mem.eql(u8, name, "standard")) return .{
        .intent = true,
        .unit = true,
        .integration = true,
        .e2e = true,
        .semantic = true,
        .trace = true,
    };

    if (std.mem.eql(u8, name, "data")) return .{
        .data_write = true,
        .data_read = true,
        .data_cache = true,
        .data_search = true,
        .data_vector = true,
        .data_graph = true,
        .data_events = true,
        .trace = true,
    };

    if (std.mem.eql(u8, name, "performance")) return .{
        .benchmark = true,
        .load = true,
        .stress = true,
        .trace = true,
    };

    if (std.mem.eql(u8, name, "full")) return .{
        .intent = true,
        .unit = true,
        .integration = true,
        .e2e = true,
        .semantic = true,
        .data_write = true,
        .data_read = true,
        .data_cache = true,
        .data_search = true,
        .data_vector = true,
        .data_graph = true,
        .data_events = true,
        .benchmark = true,
        .load = true,
        .stress = true,
        .trace = true,
        .discovery_graph = true,
        .discovery_semantic = true,
    };

    @compileError("ITI: unknown profile: " ++ name);
}

test "full enables complete trajectory verification" {
    const full = comptime fromName("full");
    try std.testing.expect(full.intent);
    try std.testing.expect(full.e2e);
    try std.testing.expect(full.data_graph);
    try std.testing.expect(full.benchmark);
    try std.testing.expect(full.discovery_semantic);
}
