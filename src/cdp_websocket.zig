const std = @import("std");

const c_socket = @extern(*const fn (c_int, c_int, c_int) callconv(.c) c_int, .{ .name = "socket" });
const c_connect = @extern(*const fn (c_int, *const anyopaque, u32) callconv(.c) c_int, .{ .name = "connect" });
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });
const c_write = @extern(*const fn (c_int, [*]const u8, usize) callconv(.c) isize, .{ .name = "write" });
const c_close = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "close" });

const SockAddrIn = extern struct {
    family: u16,
    port: u16,
    address: u32,
    zero: [8]u8,
};

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fd: c_int,
    connected: bool = true,

    pub const Error = error{
        ConnectionFailed,
        HandshakeFailed,
        WriteFailed,
        ReadFailed,
        MessageTooLarge,
        ConnectionClosed,
        InvalidFrame,
    };

    /// Open the local Lightpanda CDP endpoint. The transport deliberately refuses non-loopback hosts.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io) !WebSocketClient {
        if (@import("builtin").os.tag == .windows) return Error.ConnectionFailed;

        const fd = c_socket(2, 1, 0);
        if (fd < 0) return Error.ConnectionFailed;
        errdefer _ = c_close(fd);

        var address = SockAddrIn{
            .family = 2,
            .port = std.mem.nativeToBig(u16, 9222),
            .address = std.mem.nativeToBig(u32, 0x7f000001),
            .zero = @splat(0),
        };
        if (c_connect(fd, @ptrCast(&address), @sizeOf(SockAddrIn)) != 0) {
            return Error.ConnectionFailed;
        }

        var client = WebSocketClient{
            .allocator = allocator,
            .io = io,
            .fd = fd,
        };
        try client.upgrade();
        return client;
    }

    pub fn deinit(self: *WebSocketClient) void {
        if (!self.connected) return;
        self.sendFrame(0x8, &.{}) catch {};
        self.connected = false;
        _ = c_close(self.fd);
    }

    pub fn sendText(self: *WebSocketClient, payload: []const u8) !void {
        if (!self.connected) return Error.ConnectionClosed;
        try self.sendFrame(0x1, payload);
    }

    pub fn receiveMessageAlloc(self: *WebSocketClient, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        if (!self.connected) return Error.ConnectionClosed;
        return self.readFrameAlloc(allocator, max_size);
    }

    fn upgrade(self: *WebSocketClient) !void {
        var nonce: [16]u8 = undefined;
        self.io.random(&nonce);
        var key_buffer: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buffer, &nonce);

        var request_buffer: [1024]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buffer,
            "GET / HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:9222\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
            .{key},
        );
        try self.writeAll(request);

        var response_buffer: [4096]u8 = undefined;
        var used: usize = 0;
        while (used < response_buffer.len) {
            const count = try self.readSome(response_buffer[used..]);
            if (count == 0) return Error.HandshakeFailed;
            used += count;
            if (std.mem.indexOf(u8, response_buffer[0..used], "\r\n\r\n") != null) break;
        }
        const response = response_buffer[0..used];
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) return Error.HandshakeFailed;

        var accept_input: [24 + websocket_guid.len]u8 = undefined;
        @memcpy(accept_input[0..key.len], key);
        @memcpy(accept_input[key.len..], websocket_guid);
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(&accept_input, &digest, .{});
        var expected_buffer: [28]u8 = undefined;
        const expected = std.base64.standard.Encoder.encode(&expected_buffer, &digest);
        const expected_header = try std.fmt.allocPrint(self.allocator, "Sec-WebSocket-Accept: {s}", .{expected});
        defer self.allocator.free(expected_header);
        if (!containsIgnoreCase(response, expected_header)) return Error.HandshakeFailed;
    }

    fn sendFrame(self: *WebSocketClient, opcode: u8, payload: []const u8) !void {
        var header: [14]u8 = undefined;
        var header_len: usize = 0;
        header[header_len] = 0x80 | (opcode & 0x0f);
        header_len += 1;

        if (payload.len <= 125) {
            header[header_len] = 0x80 | @as(u8, @intCast(payload.len));
            header_len += 1;
        } else if (payload.len <= 0xffff) {
            header[header_len] = 0x80 | 126;
            header_len += 1;
            header[header_len] = @intCast((payload.len >> 8) & 0xff);
            header[header_len + 1] = @intCast(payload.len & 0xff);
            header_len += 2;
        } else {
            header[header_len] = 0x80 | 127;
            header_len += 1;
            const length: u64 = @intCast(payload.len);
            for (0..8) |index| {
                header[header_len + index] = @intCast((length >> @intCast(56 - index * 8)) & 0xff);
            }
            header_len += 8;
        }

        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        @memcpy(header[header_len .. header_len + 4], &mask);
        header_len += 4;
        try self.writeAll(header[0..header_len]);

        var offset: usize = 0;
        var chunk: [4096]u8 = undefined;
        while (offset < payload.len) {
            const count = @min(chunk.len, payload.len - offset);
            for (0..count) |index| chunk[index] = payload[offset + index] ^ mask[(offset + index) % 4];
            try self.writeAll(chunk[0..count]);
            offset += count;
        }
    }

    fn readFrameAlloc(self: *WebSocketClient, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        var header: [2]u8 = undefined;
        try self.readExact(&header);
        const final = (header[0] & 0x80) != 0;
        const opcode = header[0] & 0x0f;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7f;

        if (payload_len == 126) {
            var extended: [2]u8 = undefined;
            try self.readExact(&extended);
            payload_len = (@as(u64, extended[0]) << 8) | extended[1];
        } else if (payload_len == 127) {
            var extended: [8]u8 = undefined;
            try self.readExact(&extended);
            payload_len = 0;
            for (extended) |byte| payload_len = (payload_len << 8) | byte;
        }

        if (opcode == 0x8) {
            self.connected = false;
            return Error.ConnectionClosed;
        }
        if (opcode == 0x9) {
            if (payload_len > max_size or payload_len > std.math.maxInt(usize)) return Error.MessageTooLarge;
            const ping = try allocator.alloc(u8, @intCast(payload_len));
            defer allocator.free(ping);
            try self.readExact(ping);
            try self.sendFrame(0xA, ping);
            return self.readFrameAlloc(allocator, max_size);
        }
        if (opcode == 0xA) {
            if (payload_len > std.math.maxInt(usize)) return Error.MessageTooLarge;
            const pong = try allocator.alloc(u8, @intCast(payload_len));
            defer allocator.free(pong);
            try self.readExact(pong);
            return self.readFrameAlloc(allocator, max_size);
        }
        if (!final or opcode != 0x1) return Error.InvalidFrame;
        if (payload_len > max_size or payload_len > std.math.maxInt(usize)) return Error.MessageTooLarge;

        var mask: [4]u8 = undefined;
        if (masked) try self.readExact(&mask);
        const payload = try allocator.alloc(u8, @intCast(payload_len));
        errdefer allocator.free(payload);
        try self.readExact(payload);
        if (masked) {
            for (payload, 0..) |*byte, index| byte.* ^= mask[index % 4];
        }
        return payload;
    }

    fn writeAll(self: *WebSocketClient, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const count = c_write(self.fd, bytes.ptr + written, bytes.len - written);
            if (count <= 0) return Error.WriteFailed;
            written += @intCast(count);
        }
    }

    fn readSome(self: *WebSocketClient, bytes: []u8) !usize {
        const count = c_read(self.fd, bytes.ptr, bytes.len);
        if (count < 0) return Error.ReadFailed;
        return @intCast(count);
    }

    fn readExact(self: *WebSocketClient, bytes: []u8) !void {
        var received: usize = 0;
        while (received < bytes.len) {
            const count = try self.readSome(bytes[received..]);
            if (count == 0) return Error.ConnectionClosed;
            received += count;
        }
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

test "websocket accept hash matches the RFC 6455 example" {
    const input = "dGhlIHNhbXBsZSBub25jZQ==" ++ websocket_guid;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input, &digest, .{});
    var output: [28]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&output, &digest);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", encoded);
}
