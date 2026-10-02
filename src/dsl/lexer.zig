//! Hand-written lexer for the ITI DSL.
//!
//! Produces a token stream with 1-based line/column positions. Reserved words
//! become dedicated token kinds (see `token.keywordKind`). Comments (`#` to end
//! of line) never reach the token stream. Strings, numbers, durations, URLs and
//! paths are recognized as first-class tokens so the parser never re-scans raw
//! text.

const std = @import("std");
const token_mod = @import("token.zig");

pub const Token = token_mod.Token;
pub const Kind = token_mod.Kind;

pub const Error = error{
    UnterminatedString,
    UnknownCharacter,
    InvalidNumber,
    OutOfMemory,
};

pub const Lexer = struct {
    source: []const u8,
    file: []const u8,
    pos: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub fn init(source: []const u8, file: []const u8) Lexer {
        return .{ .source = source, .file = file };
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.pos < self.source.len) return self.source[self.pos];
        return null;
    }

    fn peekAt(self: *const Lexer, offset: usize) ?u8 {
        const i = self.pos + offset;
        if (i < self.source.len) return self.source[i];
        return null;
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn skipSpaces(self: *Lexer) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\r') _ = self.advance()
            else break;
        }
    }

    /// Returns the next token. Newlines are significant (statement separators)
    /// and emitted as `.newline` tokens. `#` comments are dropped.
    pub fn next(self: *Lexer) Error!Token {
        self.skipSpaces();

        const start_line = self.line;
        const start_col = self.column;

        const c = self.peek() orelse return .{
            .kind = .eof,
            .lexeme = "",
            .line = start_line,
            .column = start_col,
        };

        // comment: skip to end of line, then emit the newline token
        if (c == '#') {
            while (self.peek()) |ch| {
                if (ch == '\n') break;
                _ = self.advance();
            }
            return self.next();
        }

        if (c == '\n') {
            _ = self.advance();
            return .{ .kind = .newline, .lexeme = "\n", .line = start_line, .column = start_col };
        }

        if (c == '=') {
            _ = self.advance();
            return .{ .kind = .equals, .lexeme = "=", .line = start_line, .column = start_col };
        }

        if (c == '"') return self.lexString(start_line, start_col);
        if (c == '$') return self.lexVariable(start_line, start_col);
        if (isDigit(c) or ((c == '-' or c == '+') and isDigit(self.peekAt(1) orelse 0))) {
            return self.lexNumberOrDuration(start_line, start_col);
        }
        if (c == '/' or isIdentStart(c)) return self.lexWordish(start_line, start_col);

        return error.UnknownCharacter;
    }

    fn lexString(self: *Lexer, start_line: usize, start_col: usize) Error!Token {
        _ = self.advance(); // opening quote
        const content_start = self.pos;
        while (self.peek()) |ch| {
            if (ch == '\n') break;
            if (ch == '"') {
                const content = self.source[content_start..self.pos];
                _ = self.advance(); // closing quote
                return .{ .kind = .string, .lexeme = content, .line = start_line, .column = start_col };
            }
            _ = self.advance();
        }
        return error.UnterminatedString;
    }

    fn lexVariable(self: *Lexer, start_line: usize, start_col: usize) Error!Token {
        _ = self.advance(); // '$'
        const name_start = self.pos;
        while (self.peek()) |ch| {
            if (isIdentChar(ch) or ch == '.') _ = self.advance() else break;
        }
        if (self.pos == name_start) return error.UnknownCharacter;
        return .{
            .kind = .variable,
            .lexeme = self.source[name_start..self.pos],
            .line = start_line,
            .column = start_col,
        };
    }

    fn lexNumberOrDuration(self: *Lexer, start_line: usize, start_col: usize) Error!Token {
        const start = self.pos;
        var is_float = false;
        if (self.peek()) |sign| {
            if (sign == '-' or sign == '+') _ = self.advance();
        }
        while (self.peek()) |ch| {
            if (isDigit(ch)) _ = self.advance()
            else if (ch == '.' and isDigit(self.peekAt(1) orelse 0)) {
                is_float = true;
                _ = self.advance();
            } else break;
        }
        const digits = self.source[start..self.pos];

        // duration suffix directly attached: 15000ms / 5s / 1m
        if (self.peek()) |ch| {
            if (ch == 'm' or ch == 's') {
                const suffix_start = self.pos;
                _ = self.advance();
                var unit: []const u8 = "s";
                if (ch == 'm') {
                    if ((self.peek() orelse 0) == 's') {
                        _ = self.advance();
                        unit = "ms";
                    } else unit = "min";
                }
                const num_text = self.source[start..suffix_start];
                const ms = durationToMillis(num_text, unit) catch return error.InvalidNumber;
                return .{
                    .kind = .duration,
                    .lexeme = self.source[start..self.pos],
                    .milliseconds = ms,
                    .line = start_line,
                    .column = start_col,
                };
            }
        }

        const text = self.source[start..self.pos];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
            return .{
                .kind = .number,
                .lexeme = text,
                .float_value = f,
                .int_value = @intFromFloat(@trunc(f)),
                .is_float = true,
                .line = start_line,
                .column = start_col,
            };
        }
        const i = std.fmt.parseInt(i64, text, 10) catch return error.InvalidNumber;
        return .{
            .kind = .number,
            .lexeme = text,
            .int_value = i,
            .float_value = @floatFromInt(i),
            .is_float = false,
            .line = start_line,
            .column = start_col,
        };
    }

    /// Lexes identifiers, keywords, dotted observation names, paths and URLs.
    /// A leading `/` produces a path/url token; embedded `://` promotes the
    /// whole word to a url token (no full URL validation happens here — that
    /// is a semantic concern).
    fn lexWordish(self: *Lexer, start_line: usize, start_col: usize) Error!Token {
        const start = self.pos;
        var saw_slash_slash = false;

        while (self.peek()) |ch| {
            if (isIdentChar(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '/') {
                // trailing punctuation should not be swallowed by an identifier
                if (ch == '.' and !isIdentChar(self.peekAt(1) orelse 0)) break;
                if (ch == '/') {
                    if (self.peekAt(1) orelse 0 == '/' and !saw_slash_slash) {
                        saw_slash_slash = true;
                    }
                }
                _ = self.advance();
            } else if (ch == ':' and saw_slash_slash) {
                _ = self.advance();
            } else if (ch == '?') {
                _ = self.advance();
                break;
            } else break;
        }

        if (self.pos == start) return error.UnknownCharacter;
        const text = self.source[start..self.pos];

        if (text[0] == '/') {
            return .{
                .kind = if (saw_slash_slash) .url else .path,
                .lexeme = text,
                .line = start_line,
                .column = start_col,
            };
        }
        if (saw_slash_slash) {
            return .{ .kind = .url, .lexeme = text, .line = start_line, .column = start_col };
        }

        // `${sessionId}` style interpolation inside plain words is handled at
        // the parser level via string/path tokens; here we only map keywords.
        if (token_mod.keywordKind(text)) |kw| {
            var tok = Token{ .kind = kw, .lexeme = text, .line = start_line, .column = start_col };
            if (kw == .boolean) tok.bool_value = text[0] == 't';
            return tok;
        }
        return .{ .kind = .identifier, .lexeme = text, .line = start_line, .column = start_col };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

/// Converts `<value><unit>` into milliseconds. Units: ms, s, m (minutes).
pub fn durationToMillis(value_text: []const u8, unit: []const u8) !u64 {
    const v = try std.fmt.parseInt(u64, value_text, 10);
    if (std.mem.eql(u8, unit, "ms")) return v;
    if (std.mem.eql(u8, unit, "s")) return std.math.mul(u64, v, std.time.ms_per_s) catch error.InvalidNumber;
    if (std.mem.eql(u8, unit, "min")) return std.math.mul(u64, v, std.time.ms_per_min) catch error.InvalidNumber;
    return error.InvalidNumber;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn lexAll(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var list = std.ArrayList(Token).init(allocator);
    var lexer = Lexer.init(source, "<test>");
    while (true) {
        const tok = try lexer.next();
        try list.append(tok);
        if (tok.kind == .eof) break;
    }
    return list.toOwnedSlice();
}

test "lexer: I TYPE $customer.email INTO Email" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "I TYPE $customer.email INTO Email\n");

    try std.testing.expectEqual(Kind.I, toks[0].kind);
    try std.testing.expectEqual(Kind.TYPE, toks[1].kind);
    try std.testing.expectEqual(Kind.variable, toks[2].kind);
    try std.testing.expectEqualStrings("customer.email", toks[2].lexeme);
    try std.testing.expectEqual(Kind.INTO, toks[3].kind);
    try std.testing.expectEqual(Kind.identifier, toks[4].kind);
    try std.testing.expectEqualStrings("Email", toks[4].lexeme);
    try std.testing.expectEqual(Kind.newline, toks[5].kind);
}

test "lexer: I HOPE JSON ok = true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "I HOPE JSON ok = true");
    try std.testing.expectEqual(Kind.HOPE, toks[1].kind);
    try std.testing.expectEqual(Kind.JSON, toks[2].kind);
    try std.testing.expectEqual(Kind.identifier, toks[3].kind);
    try std.testing.expectEqual(Kind.equals, toks[4].kind);
    try std.testing.expectEqual(Kind.boolean, toks[5].kind);
    try std.testing.expect(toks[5].bool_value);
}

test "lexer: RUNTIME startup-timeout 15000ms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "RUNTIME startup-timeout 15000ms");
    try std.testing.expectEqual(Kind.RUNTIME, toks[0].kind);
    try std.testing.expectEqual(Kind.identifier, toks[1].kind);
    try std.testing.expectEqualStrings("startup-timeout", toks[1].lexeme);
    try std.testing.expectEqual(Kind.duration, toks[2].kind);
    try std.testing.expectEqual(@as(u64, 15000), toks[2].milliseconds);
}

test "lexer: durations 5s and 1m normalize to ms" {
    try std.testing.expectEqual(@as(u64, 5000), try durationToMillis("5", "s"));
    try std.testing.expectEqual(@as(u64, 60000), try durationToMillis("1", "min"));
    try std.testing.expectEqual(@as(u64, 15000), try durationToMillis("15000", "ms"));
}

test "lexer: MOCK pattern string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "I MOCK \"https://maps.googleapis.com/maps/api/js**\"");
    try std.testing.expectEqual(Kind.MOCK, toks[1].kind);
    try std.testing.expectEqual(Kind.string, toks[2].kind);
    try std.testing.expectEqualStrings("https://maps.googleapis.com/maps/api/js**", toks[2].lexeme);
}

test "lexer: CDP endpoint becomes url token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "RUNTIME cdp http://127.0.0.1:9222");
    try std.testing.expectEqual(Kind.url, toks[2].kind);
    try std.testing.expectEqualStrings("http://127.0.0.1:9222", toks[2].lexeme);
}

test "lexer: negative floats and paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "WITH latitude = -23.5489\nI GET /api/geocode");
    try std.testing.expectEqual(Kind.number, toks[3].kind);
    try std.testing.expect(toks[3].is_float);
    try std.testing.expectApproxEqAbs(@as(f64, -23.5489), toks[3].float_value, 0.00001);
    try std.testing.expectEqual(Kind.path, toks[7].kind);
    try std.testing.expectEqualStrings("/api/geocode", toks[7].lexeme);
}

test "lexer: comments are skipped and positions preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lexAll(arena.allocator(), "# hello\nPROFILE full\n");
    try std.testing.expectEqual(Kind.PROFILE, toks[0].kind);
    try std.testing.expectEqual(@as(usize, 2), toks[0].line);
    try std.testing.expectEqual(@as(usize, 1), toks[0].column);
    try std.testing.expectEqualStrings("full", toks[1].lexeme);
}

test "lexer: unterminated string reports error" {
    var lexer = Lexer.init("I OPEN \"oops", "<test>");
    _ = lexer.next() catch {};
    try std.testing.expectError(error.UnterminatedString, lexer.next());
}
