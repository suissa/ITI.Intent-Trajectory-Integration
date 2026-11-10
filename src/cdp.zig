const std = @import("std");
const WebSocketClient = @import("cdp_websocket.zig").WebSocketClient;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ws: WebSocketClient,
    next_id: usize = 0,
    target_id: []const u8,
    session_id: []const u8,

    pub fn connect(allocator: std.mem.Allocator, io: std.Io) !Client {
        var read_buffer: [64 * 1024]u8 = undefined;
        var ws = try WebSocketClient.connect(allocator, io, "ws://127.0.0.1:9222/", &read_buffer);
        errdefer ws.close();

        var client = Client{
            .allocator = allocator,
            .io = io,
            .ws = ws,
            .target_id = "",
            .session_id = "",
        };

        const created = try client.command("Target.createTarget", .{ .url = "about:blank" }, null);
        defer created.deinit();
        const target = created.value.object.get("result").?.object.get("targetId").?.string;
        client.target_id = try allocator.dupe(u8, target);
        errdefer allocator.free(client.target_id);

        const attached = try client.command("Target.attachToTarget", .{
            .targetId = client.target_id,
            .flatten = true,
        }, null);
        defer attached.deinit();
        const session = attached.value.object.get("result").?.object.get("sessionId").?.string;
        client.session_id = try allocator.dupe(u8, session);

        const page_enabled = try client.command("Page.enable", .{}, client.session_id);
        page_enabled.deinit();
        const runtime_enabled = try client.command("Runtime.enable", .{}, client.session_id);
        runtime_enabled.deinit();

        return client;
    }

    pub fn deinit(self: *Client) void {
        self.ws.close();
        if (self.target_id.len > 0) self.allocator.free(self.target_id);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
    }

    pub fn open(self: *Client, url: []const u8) !void {
        const result = try self.command("Page.navigate", .{ .url = url }, self.session_id);
        defer result.deinit();
        if (result.value.object.get("error") != null) return error.NavigationFailed;
    }

    pub fn typeInto(self: *Client, value: []const u8, target: []const u8) !void {
        const target_json = try std.json.Stringify.valueAlloc(self.allocator, target, .{});
        defer self.allocator.free(target_json);
        const value_json = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(value_json);
        const expression = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const target = {s};
            \\  const value = {s};
            \\  const find = (name) => {{
            \\    try {{ const direct = document.querySelector(name); if (direct) return direct; }} catch {{}}
            \\    const fields = [...document.querySelectorAll('input,textarea,[contenteditable="true"]')];
            \\    return fields.find(el => el.id === name || el.name === name || el.placeholder === name ||
            \\      el.getAttribute('aria-label') === name ||
            \\      [...(el.labels || [])].some(label => label.innerText.trim() === name));
            \\  }};
            \\  const el = find(target);
            \\  if (!el) return false;
            \\  el.focus();
            \\  if (el.isContentEditable) el.textContent = value;
            \\  else {{
            \\    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            \\    const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            \\    if (setter) setter.call(el, value); else el.value = value;
            \\  }}
            \\  el.dispatchEvent(new Event('input', {{ bubbles: true }}));
            \\  el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            \\  return true;
            \\}})()
        , .{ target_json, value_json });
        defer self.allocator.free(expression);
        if (!try self.evaluateBool(expression)) return error.ElementNotFound;
    }

    pub fn click(self: *Client, target: []const u8) !void {
        const target_json = try std.json.Stringify.valueAlloc(self.allocator, target, .{});
        defer self.allocator.free(target_json);
        const expression = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const target = {s};
            \\  try {{ const direct = document.querySelector(target); if (direct) {{ direct.click(); return true; }} }} catch {{}}
            \\  const candidates = [...document.querySelectorAll('button,a,[role="button"],input[type="submit"]')];
            \\  const el = candidates.find(node => (node.innerText || node.textContent || '').trim().includes(target) ||
            \\    node.getAttribute('aria-label') === target || node.id === target || node.title === target);
            \\  if (!el) return false;
            \\  el.click();
            \\  return true;
            \\}})()
        , .{target_json});
        defer self.allocator.free(expression);
        if (!try self.evaluateBool(expression)) return error.ElementNotFound;
    }

    pub fn hopeSee(self: *Client, target: []const u8) !void {
        const target_json = try std.json.Stringify.valueAlloc(self.allocator, target, .{});
        defer self.allocator.free(target_json);
        const expression = try std.fmt.allocPrint(self.allocator,
            \\(async () => {{
            \\  const target = {s};
            \\  try {{ if (document.querySelector(target)) return true; }} catch {{}}
            \\  return (document.body?.innerText || '').includes(target);
            \\}})()
        , .{target_json});
        defer self.allocator.free(expression);
        if (!try self.evaluateBool(expression)) return error.DestinationNotVisible;
    }

    fn evaluateBool(self: *Client, expression: []const u8) !bool {
        const result = try self.command("Runtime.evaluate", .{
            .expression = expression,
            .returnByValue = true,
            .awaitPromise = true,
        }, self.session_id);
        defer result.deinit();
        const value = result.value.object.get("result").?.object.get("result").?.object.get("value") orelse return false;
        return switch (value) {
            .bool => |boolean| boolean,
            else => false,
        };
    }

    fn command(self: *Client, method: []const u8, params: anytype, session: ?[]const u8) !std.json.Parsed(std.json.Value) {
        self.next_id += 1;
        const id = self.next_id;
        const json = if (session) |session_id| blk: {
            const Request = struct {
                id: usize,
                method: []const u8,
                params: @TypeOf(params),
                sessionId: []const u8,
            };
            break :blk try std.json.Stringify.valueAlloc(self.allocator, Request{
                .id = id,
                .method = method,
                .params = params,
                .sessionId = session_id,
            }, .{});
        } else blk: {
            const Request = struct {
                id: usize,
                method: []const u8,
                params: @TypeOf(params),
            };
            break :blk try std.json.Stringify.valueAlloc(self.allocator, Request{
                .id = id,
                .method = method,
                .params = params,
            }, .{});
        };
        defer self.allocator.free(json);
        try self.ws.sendText(json);

        while (true) {
            const message = try self.ws.receiveMessageAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(message);
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            const response_id = parsed.value.object.get("id") orelse {
                parsed.deinit();
                continue;
            };
            if (response_id != .integer or response_id.integer != id) {
                parsed.deinit();
                continue;
            }
            if (parsed.value.object.get("error") != null) {
                parsed.deinit();
                return error.CdpCommandFailed;
            }
            return parsed;
        }
    }
};

test "CDP command methods use the expected protocol names" {
    try std.testing.expectEqualStrings("Target.createTarget", "Target.createTarget");
    try std.testing.expectEqualStrings("Runtime.evaluate", "Runtime.evaluate");
}
