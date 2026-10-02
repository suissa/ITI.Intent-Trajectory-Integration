//! Structured error type for the ITI DSL. Every parse/validate failure keeps
//! file, line and column so diagnostics can point at the exact source span.

const std = @import("std");
const token_mod = @import("token.zig");

pub const Kind = enum {
    unexpected_token,
    unexpected_eof,
    invalid_profile,
    invalid_actor,
    invalid_runtime,
    invalid_observation,
    missing_into,
    invalid_expression,
    unclosed_block,
    unexpected_end,
    invalid_with_clause,
    undefined_variable,
    invalid_number,
    unterminated_string,
    unknown_character,
};

pub const Error = error{
    UnexpectedToken,
    UnexpectedEOF,
    InvalidProfile,
    InvalidActor,
    InvalidRuntime,
    InvalidObservation,
    MissingInto,
    InvalidExpression,
    UnclosedBlock,
    UnexpectedEnd,
    InvalidWithClause,
    UndefinedVariable,
    InvalidNumber,
    UnterminatedString,
    UnknownCharacter,
};

/// A diagnostic with position + optional source excerpt and hint.
pub const Diagnostic = struct {
    file: []const u8,
    kind: Kind,
    message: []const u8,
    hint: ?[]const u8 = null,
    line: usize = 1,
    column: usize = 1,

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const alloc = fba.allocator();

        try writer.print("{s}:{d}:{d}: {s}", .{ self.file, self.line, self.column, self.message });
        if (self.hint) |hint| {
            const indented = try std.mem.replaceOwned(u8, alloc, hint, "\n", "\n    ");
            try writer.print("\n    {s}", .{indented});
        }
        try writer.print("\n", .{});
    }
};

/// Formats Zig's `error` union set into a human-readable tag name.
pub fn errorName(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "OutOfMemory",
        error.UnexpectedToken => "UnexpectedToken",
        error.UnexpectedEOF => "UnexpectedEOF",
        error.InvalidProfile => "InvalidProfile",
        error.InvalidActor => "InvalidActor",
        error.InvalidRuntime => "InvalidRuntime",
        error.InvalidObservation => "InvalidObservation",
        error.MissingInto => "MissingInto",
        error.InvalidExpression => "InvalidExpression",
        error.UnclosedBlock => "UnclosedBlock",
        error.UnexpectedEnd => "UnexpectedEnd",
        error.InvalidWithClause => "InvalidWithClause",
        error.UndefinedVariable => "UndefinedVariable",
        error.InvalidNumber => "InvalidNumber",
        error.UnterminatedString => "UnterminatedString",
        error.UnknownCharacter => "UnknownCharacter",
        else => @errorName(err),
    };
}

comptime {
    _ = token_mod;
}
