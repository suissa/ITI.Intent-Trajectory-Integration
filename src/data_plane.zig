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
    fail: bool = false,

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
        if (self.fail) return error.ProbeFailed;
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
    var second = MemoryAdapter{ .fail = true };
    var third = MemoryAdapter{};
    try registry.register(first.asAdapter("read-store", CapabilitySet.init(&.{.read})));
    try registry.register(second.asAdapter("failing-read-store", CapabilitySet.init(&.{.read})));
    try registry.register(third.asAdapter("write-store", CapabilitySet.init(&.{.write})));

    const outcomes = try registry.probeAll(.read, std.testing.io, .{ .correlation_id = "corr-all" });
    defer std.testing.allocator.free(outcomes);

    try std.testing.expectEqual(@as(usize, 2), outcomes.len);
    try std.testing.expectEqualStrings("read-store", outcomes[0].adapter_id);
    try std.testing.expectEqual(ProbeStatus.passed, outcomes[0].result.status);
    try std.testing.expectEqualStrings("failing-read-store", outcomes[1].adapter_id);
    try std.testing.expectEqual(ProbeStatus.failed, outcomes[1].result.status);
    try std.testing.expectEqualStrings("ProbeFailed", outcomes[1].result.detail);
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
}


pub const AdapterDescriptor = struct {
    id: []const u8,
    driver: []const u8,
    capabilities: CapabilitySet = .{},
    endpoint_env: []const u8 = "",
    credential_env: []const u8 = "",
};

pub const ResolvedConfig = struct {
    endpoint: ?[]const u8 = null,
    credential: ?[]const u8 = null,
};

pub const FactoryFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    descriptor: AdapterDescriptor,
    resolved: ResolvedConfig,
    io: std.Io,
) anyerror!Adapter;

pub const DriverFactory = struct {
    name: []const u8,
    context: ?*anyopaque = null,
    create_fn: FactoryFn,
};

/// Owns the adapter registry and driver-factory instances for one ITI process.
pub const Runtime = struct {
    arena: std.heap.ArenaAllocator,
    registry: Registry,
    factories: std.ArrayListUnmanaged(DriverFactory) = .empty,

    pub fn init(parent_allocator: std.mem.Allocator) !Runtime {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        var runtime = Runtime{
            .arena = arena,
            .registry = Registry.init(arena.allocator()),
        };
        try runtime.registerFactory("memory", null, createMemoryAdapter);
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        const allocator = self.arena.allocator();
        self.registry.deinit();
        self.factories.deinit(allocator);
        self.arena.deinit();
    }

    pub fn registerFactory(self: *Runtime, name: []const u8, context: ?*anyopaque, create_fn: FactoryFn) !void {
        if (name.len == 0) return error.InvalidDriverName;
        for (self.factories.items) |factory| {
            if (std.mem.eql(u8, factory.name, name)) return error.DuplicateDriverFactory;
        }
        try self.factories.append(self.arena.allocator(), .{
            .name = name,
            .context = context,
            .create_fn = create_fn,
        });
    }

    pub fn load(
        self: *Runtime,
        source: []const u8,
        environ: *const std.process.Environ.Map,
        io: std.Io,
    ) !void {
        const allocator = self.arena.allocator();
        const descriptors = try parseConfig(allocator, source);
        defer allocator.free(descriptors);

        const original_adapter_count = self.registry.adapters.items.len;
        errdefer self.registry.adapters.items.len = original_adapter_count;

        for (descriptors) |descriptor| {
            const factory = self.findFactory(descriptor.driver) orelse return error.UnknownDriver;
            const resolved = ResolvedConfig{
                .endpoint = if (descriptor.endpoint_env.len == 0)
                    null
                else
                    environ.get(descriptor.endpoint_env) orelse return error.MissingEndpointEnvironmentVariable,
                .credential = if (descriptor.credential_env.len == 0)
                    null
                else
                    environ.get(descriptor.credential_env) orelse return error.MissingCredentialEnvironmentVariable,
            };
            if (resolved.endpoint) |endpoint| {
                if (endpoint.len == 0) return error.EmptyEndpointEnvironmentVariable;
            }
            if (resolved.credential) |credential| {
                if (credential.len == 0) return error.EmptyCredentialEnvironmentVariable;
            }

            const adapter = try factory.create_fn(factory.context, allocator, descriptor, resolved, io);
            try self.registry.register(adapter);
        }
    }

    fn findFactory(self: *Runtime, name: []const u8) ?DriverFactory {
        for (self.factories.items) |factory| {
            if (std.mem.eql(u8, factory.name, name)) return factory;
        }
        return null;
    }
};

pub fn parseConfig(allocator: std.mem.Allocator, source: []const u8) ![]AdapterDescriptor {
    var descriptors: std.ArrayListUnmanaged(AdapterDescriptor) = .empty;
    errdefer descriptors.deinit(allocator);
    var current: ?AdapterDescriptor = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |comment| line = std.mem.trim(u8, line[0..comment], " \t\r");
        if (line.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const directive = tokens.next() orelse continue;
        if (std.mem.eql(u8, directive, "adapter")) {
            if (current) |descriptor| try appendDescriptor(&descriptors, allocator, descriptor);
            const id = tokens.next() orelse return error.InvalidAdapterDirective;
            const driver = tokens.next() orelse return error.InvalidAdapterDirective;
            if (tokens.next() != null) return error.InvalidAdapterDirective;
            current = .{ .id = id, .driver = driver };
            continue;
        }

        const descriptor = if (current) |*value| value else return error.DirectiveBeforeAdapter;
        if (std.mem.eql(u8, directive, "capabilities")) {
            var count: usize = 0;
            while (tokens.next()) |name| {
                const capability = std.meta.stringToEnum(Capability, name) orelse return error.UnknownCapability;
                descriptor.capabilities.add(capability);
                count += 1;
            }
            if (count == 0) return error.EmptyCapabilities;
        } else if (std.mem.eql(u8, directive, "endpoint-env")) {
            if (descriptor.endpoint_env.len > 0) return error.DuplicateEndpointEnvironmentVariable;
            descriptor.endpoint_env = tokens.next() orelse return error.InvalidEnvironmentDirective;
            if (tokens.next() != null) return error.InvalidEnvironmentDirective;
        } else if (std.mem.eql(u8, directive, "credential-env")) {
            if (descriptor.credential_env.len > 0) return error.DuplicateCredentialEnvironmentVariable;
            descriptor.credential_env = tokens.next() orelse return error.InvalidEnvironmentDirective;
            if (tokens.next() != null) return error.InvalidEnvironmentDirective;
        } else {
            return error.UnknownConfigDirective;
        }
    }

    if (current) |descriptor| try appendDescriptor(&descriptors, allocator, descriptor);
    return descriptors.toOwnedSlice(allocator);
}

fn appendDescriptor(
    descriptors: *std.ArrayListUnmanaged(AdapterDescriptor),
    allocator: std.mem.Allocator,
    descriptor: AdapterDescriptor,
) !void {
    if (descriptor.id.len == 0 or descriptor.driver.len == 0) return error.InvalidAdapterDescriptor;
    if (descriptor.capabilities.count() == 0) return error.EmptyCapabilities;
    for (descriptors.items) |existing| {
        if (std.mem.eql(u8, existing.id, descriptor.id)) return error.DuplicateAdapterId;
    }
    try descriptors.append(allocator, descriptor);
}

fn createMemoryAdapter(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    descriptor: AdapterDescriptor,
    resolved: ResolvedConfig,
    io: std.Io,
) anyerror!Adapter {
    _ = context;
    _ = resolved;
    _ = io;
    const memory = try allocator.create(MemoryAdapter);
    memory.* = .{};
    return memory.asAdapter(descriptor.id, descriptor.capabilities);
}

test "DataPlane config parses adapters, capabilities and environment references" {
    const source =
        "# local test adapter\n" ++
        "adapter primary memory\n" ++
        "capabilities read write cache\n" ++
        "endpoint-env ITI_DATA_ENDPOINT\n" ++
        "credential-env ITI_DATA_TOKEN\n" ++
        "adapter archive memory\n" ++
        "capabilities read graph\n";
    const descriptors = try parseConfig(std.testing.allocator, source);
    defer std.testing.allocator.free(descriptors);

    try std.testing.expectEqual(@as(usize, 2), descriptors.len);
    try std.testing.expectEqualStrings("primary", descriptors[0].id);
    try std.testing.expectEqualStrings("memory", descriptors[0].driver);
    try std.testing.expect(descriptors[0].capabilities.contains(.write));
    try std.testing.expectEqualStrings("ITI_DATA_ENDPOINT", descriptors[0].endpoint_env);
    try std.testing.expectEqualStrings("ITI_DATA_TOKEN", descriptors[0].credential_env);
    try std.testing.expectEqualStrings("archive", descriptors[1].id);
    try std.testing.expect(descriptors[1].capabilities.contains(.graph));
}

test "DataPlane config rejects invalid directives and duplicate IDs" {
    try std.testing.expectError(error.DirectiveBeforeAdapter, parseConfig(std.testing.allocator, "capabilities read"));
    try std.testing.expectError(error.UnknownCapability, parseConfig(std.testing.allocator, "adapter bad memory\ncapabilities read database"));
    try std.testing.expectError(error.DuplicateAdapterId, parseConfig(std.testing.allocator, "adapter same memory\ncapabilities read\nadapter same memory\ncapabilities write"));
}

test "DataPlane runtime resolves configured environment values without exposing them in probe results" {
    const Capture = struct {
        endpoint: []const u8 = "",
        credential: []const u8 = "",
    };
    const captureFactory = struct {
        fn create(
            context: ?*anyopaque,
            allocator: std.mem.Allocator,
            descriptor: AdapterDescriptor,
            resolved: ResolvedConfig,
            io: std.Io,
        ) anyerror!Adapter {
            _ = io;
            const capture: *Capture = @ptrCast(@alignCast(context.?));
            capture.endpoint = resolved.endpoint orelse "";
            capture.credential = resolved.credential orelse "";
            const memory = try allocator.create(MemoryAdapter);
            memory.* = .{};
            return memory.asAdapter(descriptor.id, descriptor.capabilities);
        }
    }.create;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ITI_DATA_ENDPOINT", "https://data.internal");
    try environ.put("ITI_DATA_TOKEN", "super-secret-token");

    var capture = Capture{};
    var runtime = try Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.registerFactory("capture", &capture, captureFactory);
    try runtime.load(
        "adapter primary capture\ncapabilities read\nendpoint-env ITI_DATA_ENDPOINT\ncredential-env ITI_DATA_TOKEN\n",
        &environ,
        std.testing.io,
    );

    try std.testing.expectEqualStrings("https://data.internal", capture.endpoint);
    try std.testing.expectEqualStrings("super-secret-token", capture.credential);
    const outcome = try runtime.registry.probe("primary", .read, std.testing.io, .{ .correlation_id = "corr-config" });
    try std.testing.expectEqual(ProbeStatus.passed, outcome.result.status);
    try std.testing.expect(std.mem.indexOf(u8, outcome.result.detail, "super-secret-token") == null);
}

test "DataPlane runtime rejects missing secrets and unknown driver factories" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    var runtime = try Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expectError(
        error.MissingCredentialEnvironmentVariable,
        runtime.load("adapter primary memory\ncapabilities read\ncredential-env ITI_DATA_TOKEN\n", &environ, std.testing.io),
    );
    try std.testing.expectError(
        error.UnknownDriver,
        runtime.load("adapter primary postgres\ncapabilities read\n", &environ, std.testing.io),
    );
}
