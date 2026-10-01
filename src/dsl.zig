const std = @import("std");

pub const StepKind = enum {
    actor,
    open,
    type_into,
    click,
    wish,
    hope_see,
    hope,
    with,
};

pub const Step = struct {
    kind: StepKind,
    raw: []const u8,
    subject: []const u8 = "",
    object: []const u8 = "",
    value: []const u8 = "",
};

pub fn Parsed(comptime n: usize) type {
    return struct {
        steps: [n]Step,
    };
}

pub fn parse(comptime source: []const u8) Parsed(countSteps(source)) {
    const n = countSteps(source);
    var out: [n]Step = undefined;
    var index: usize = 0;
    var start: usize = 0;

    while (start <= source.len) {
        const end = findByteFrom(source, start, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[start..end], " \t\r");

        if (line.len != 0 and line[0] != '#') {
            out[index] = parseLine(line);
            index += 1;
        }

        if (end == source.len) break;
        start = end + 1;
    }

    return .{ .steps = out };
}

fn countSteps(comptime source: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;

    while (start <= source.len) {
        const end = findByteFrom(source, start, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[start..end], " \t\r");
        if (line.len != 0 and line[0] != '#') count += 1;
        if (end == source.len) break;
        start = end + 1;
    }

    return count;
}

fn parseLine(comptime line: []const u8) Step {
    if (std.mem.startsWith(u8, line, "AS ")) {
        const rest = line[3..];
        const sep = findByte(rest, ' ') orelse
            @compileError("ITI: AS requires actor type and identifier");
        return .{
            .kind = .actor,
            .raw = line,
            .subject = rest[0..sep],
            .object = std.mem.trim(u8, rest[sep + 1 ..], " "),
        };
    }

    if (std.mem.startsWith(u8, line, "I OPEN ")) {
        return simple(.open, line, line[7..]);
    }

    if (std.mem.startsWith(u8, line, "I CLICK ")) {
        return simple(.click, line, line[8..]);
    }

    if (std.mem.startsWith(u8, line, "I WISH ")) {
        return simple(.wish, line, line[7..]);
    }

    if (std.mem.startsWith(u8, line, "I HOPE SEE ")) {
        return simple(.hope_see, line, line[11..]);
    }

    if (std.mem.startsWith(u8, line, "I HOPE ")) {
        return simple(.hope, line, line[7..]);
    }

    if (std.mem.startsWith(u8, line, "WITH ")) {
        return simple(.with, line, line[5..]);
    }

    if (std.mem.startsWith(u8, line, "I TYPE ")) {
        const body = line[7..];
        const marker = " INTO ";
        const sep = findSlice(body, marker) orelse
            @compileError("ITI: I TYPE requires INTO");
        return .{
            .kind = .type_into,
            .raw = line,
            .value = std.mem.trim(u8, body[0..sep], " "),
            .object = std.mem.trim(u8, body[sep + marker.len ..], " "),
        };
    }

    @compileError("ITI: unsupported DSL statement: " ++ line);
}

fn simple(comptime kind: StepKind, comptime raw: []const u8, comptime object: []const u8) Step {
    const trimmed = std.mem.trim(u8, object, " ");
    if (trimmed.len == 0) @compileError("ITI: statement requires a value: " ++ raw);
    return .{ .kind = kind, .raw = raw, .object = trimmed };
}

fn findByte(comptime haystack: []const u8, comptime needle: u8) ?usize {
    return findByteFrom(haystack, 0, needle);
}

fn findByteFrom(comptime haystack: []const u8, comptime start: usize, comptime needle: u8) ?usize {
    var i = start;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    return null;
}

fn findSlice(comptime haystack: []const u8, comptime needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "parses natural browser behavior at comptime" {
    const spec =
        \\AS Human $customer
        \\I OPEN Login
        \\I TYPE $customer.email INTO Email
        \\I TYPE $customer.password INTO Password
        \\I CLICK Login
        \\I HOPE SEE Dashboard
    ;

    const parsed = comptime parse(spec);
    try std.testing.expectEqual(@as(usize, 6), parsed.steps.len);
    try std.testing.expectEqual(StepKind.actor, parsed.steps[0].kind);
    try std.testing.expectEqualStrings("Human", parsed.steps[0].subject);
    try std.testing.expectEqualStrings("Dashboard", parsed.steps[5].object);
}
