const std = @import("std");

pub const Capability = enum(u3) {
    read,
    write,
    cache,
    search,
    vector,
    graph,
    events,
};

pub const CapabilitySet = struct {
    bits: u8 = 0,

    pub fn init(capabilities: []const Capability) CapabilitySet {
        var set = CapabilitySet{};
        for (capabilities) |capability| set.add(capability);
        return set;
    }

    pub fn add(self: *CapabilitySet, capability: Capability) void {
        self.bits |= @as(u8, 1) << @intFromEnum(capability);
    }

    pub fn contains(self: CapabilitySet, capability: Capability) bool {
        return (self.bits & (@as(u8, 1) << @intFromEnum(capability))) != 0;
    }

    pub fn count(self: CapabilitySet) usize {
        return @intCast(@popCount(self.bits));
    }
};

pub const ProbeContext = struct {
    correlation_id: []const u8 = "",
    causation_id: []const u8 = "",
    actor_type: []const u8 = "",
    subject_id: []const u8 = "",
    intent_id: []const u8 = "",
    behavior_id: []const u8 = "",
    action_id: []const u8 = "",
};

pub const ProbeStatus = enum {
    passed,
    failed,
    skipped,
};

pub const ProbeResult = struct {
    status: ProbeStatus,
    duration_ms: u64 = 0,
    detail: []const u8 = "",
};

pub const ProbeFn = *const fn (
    context: *anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    capability: Capability,
    probe_context: ProbeContext,
) anyerror!ProbeResult;

pub const Adapter = struct {
    id: []const u8,
    capabilities: CapabilitySet,
    context: *anyopaque,
    probe_fn: ProbeFn,

    pub fn supports(self: Adapter, capability: Capability) bool {
        return self.capabilities.contains(capability);
    }

    pub fn probe(
        self: Adapter,
        allocator: std.mem.Allocator,
        io: std.Io,
        capability: Capability,
        probe_context: ProbeContext,
    ) !ProbeResult {
        if (!self.supports(capability)) return error.CapabilityUnsupported;
        return self.probe_fn(self.context, allocator, io, capability, probe_context);
    }
};

pub const ProbeOutcome = struct {
    adapter_id: []const u8,
    capability: Capability,
    result: ProbeResult,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    adapters: std.ArrayListUnmanaged(Adapter) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.adapters.deinit(self.allocator);
    }

    pub fn register(self: *Registry, adapter: Adapter) !void {
        if (adapter.id.len == 0) return error.InvalidAdapterId;
        for (self.adapters.items) |existing| {
            if (std.mem.eql(u8, existing.id, adapter.id)) return error.DuplicateAdapterId;
        }
        try self.adapters.append(self.allocator, adapter);
    }

    pub fn find(self: *Registry, id: []const u8) ?*const Adapter {
        for (self.adapters.items) |*adapter| {
            if (std.mem.eql(u8, adapter.id, id)) return adapter;
        }
        return null;
    }

    pub fn probe(
        self: *Registry,
        id: []const u8,
        capability: Capability,
        io: std.Io,
        probe_context: ProbeContext,
    ) !ProbeOutcome {
        const adapter = self.find(id) orelse return error.AdapterNotFound;
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        var result = try adapter.probe(self.allocator, io, capability, probe_context);
        const ended = std.Io.Clock.awake.now(io).nanoseconds;
        if (ended > started) {
            result.duration_ms = @intCast(@divTrunc(ended - started, 1_000_000));
        }
        return .{
            .adapter_id = adapter.id,
            .capability = capability,
            .result = result,
        };
    }

    /// Probe every registered adapter that declares the requested capability.
    /// Adapter failures become explicit failed outcomes; they do not abort peers.
    pub fn probeAll(
        self: *Registry,
        capability: Capability,
        io: std.Io,
        probe_context: ProbeContext,
    ) ![]ProbeOutcome {
        var outcomes: std.ArrayListUnmanaged(ProbeOutcome) = .empty;
        errdefer outcomes.deinit(self.allocator);

        for (self.adapters.items) |adapter| {
            if (!adapter.supports(capability)) continue;
            const started = std.Io.Clock.awake.now(io).nanoseconds;
            var result: ProbeResult = adapter.probe(self.allocator, io, capability, probe_context) catch |err| ProbeResult{
                .status = .failed,
                .detail = @errorName(err),
            };
            const ended = std.Io.Clock.awake.now(io).nanoseconds;
            if (ended > started) {
                result.duration_ms = @intCast(@divTrunc(ended - started, 1_000_000));
            }
            try outcomes.append(self.allocator, .{
                .adapter_id = adapter.id,
                .capability = capability,
                .result = result,
            });
        }

        return outcomes.toOwnedSlice(self.allocator);
    }
};

/// Deterministic adapter used by tests and local behavior fixtures.
pub const MemoryAdapter = struct {
    calls: usize = 0,
    last_capability: ?Capability = null,
    last_correlation_id: []const u8 = "",
    last_actor_type: []const u8 = "",
    last_subject_id: []const u8 = "",

    pub fn asAdapter(self: *MemoryAdapter, id: []const u8, capabilities: CapabilitySet) Adapter {
        return .{
            .id = id,
            .capabilities = capabilities,
            .context = self,
            .probe_fn = probeMemory,
        };
    }

    fn probeMemory(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        capability: Capability,
        probe_context: ProbeContext,
    ) anyerror!ProbeResult {
        _ = allocator;
        _ = io;
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last_capability = capability;
        self.last_correlation_id = probe_context.correlation_id;
        self.last_actor_type = probe_context.actor_type;
        self.last_subject_id = probe_context.subject_id;
        return .{
            .status = .passed,
            .detail = "memory adapter probe passed",
        };
    }
};

test "capability sets support deterministic membership and counting" {
    const capabilities = [_]Capability{ .read, .write, .graph };
    const set = CapabilitySet.init(&capabilities);
    try std.testing.expect(set.contains(.read));
    try std.testing.expect(set.contains(.write));
    try std.testing.expect(set.contains(.graph));
    try std.testing.expect(!set.contains(.vector));
    try std.testing.expectEqual(@as(usize, 3), set.count());
}

test "registry rejects empty and duplicate adapter identifiers" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var memory = MemoryAdapter{};
    const capabilities = CapabilitySet.init(&.{.read});
    try std.testing.expectError(error.InvalidAdapterId, registry.register(memory.asAdapter("", capabilities)));
    try registry.register(memory.asAdapter("primary", capabilities));
    try std.testing.expectError(error.DuplicateAdapterId, registry.register(memory.asAdapter("primary", capabilities)));
    try std.testing.expect(registry.find("primary") != null);
    try std.testing.expect(registry.find("missing") == null);
}

test "registry validates capabilities and preserves trajectory identity" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var memory = MemoryAdapter{};
    try registry.register(memory.asAdapter("memory", CapabilitySet.init(&.{ .read, .write })));

    const context = ProbeContext{
        .correlation_id = "corr-123",
        .actor_type = "Human",
        .subject_id = "$customer",
        .intent_id = "intent-checkout",
    };

    try std.testing.expectError(error.CapabilityUnsupported, registry.probe("memory", .vector, std.testing.io, context));
    try std.testing.expectError(error.AdapterNotFound, registry.probe("missing", .read, std.testing.io, context));

    const outcome = try registry.probe("memory", .read, std.testing.io, context);
    try std.testing.expectEqualStrings("memory", outcome.adapter_id);
    try std.testing.expectEqual(Capability.read, outcome.capability);
    try std.testing.expectEqual(ProbeStatus.passed, outcome.result.status);
    try std.testing.expectEqual(@as(usize, 1), memory.calls);
    try std.testing.expectEqualStrings("corr-123", memory.last_correlation_id);
    try std.testing.expectEqualStrings("Human", memory.last_actor_type);
    try std.testing.expectEqualStrings("$customer", memory.last_subject_id);
}

test "probeAll isolates adapter failures and returns only capable adapters" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var first = MemoryAdapter{};
    var second = MemoryAdapter{};
    try registry.register(first.asAdapter("read-store", CapabilitySet.init(&.{.read})));
    try registry.register(second.asAdapter("write-store", CapabilitySet.init(&.{.write})));

    const outcomes = try registry.probeAll(.read, std.testing.io, .{ .correlation_id = "corr-all" });
    defer std.testing.allocator.free(outcomes);

    try std.testing.expectEqual(@as(usize, 1), outcomes.len);
    try std.testing.expectEqualStrings("read-store", outcomes[0].adapter_id);
    try std.testing.expectEqual(ProbeStatus.passed, outcomes[0].result.status);
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 0), second.calls);
}
