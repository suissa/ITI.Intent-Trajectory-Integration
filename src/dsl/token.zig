//! Token definitions for the ITI DSL.
//!
//! Reserved words are recognized explicitly by the lexer: they become their
//! own token kinds instead of plain identifiers, so the parser never has to
//! compare reserved words as strings.

const std = @import("std");

/// Lexical class of a token. Keywords map 1:1 to grammar productions.
pub const Kind = enum {
    eof,

    identifier,
    variable,
    string,
    number,
    boolean,
    path,
    url,
    duration,

    newline,

    equals,

    PROFILE,
    BENCHMARK,
    ON,
    OFF,

    RUNTIME,
    OBSERVE,

    BEHAVIOR,
    AS,
    Human,
    Agent,

    I,
    OPEN,
    TYPE,
    INTO,
    CLICK,
    SELECT,
    BLUR,
    GRANT,
    MOCK,

    GET,
    POST,

    WITH,
    JSON,

    SAVE,
    RESPONSE,

    LET,

    FOR,
    EACH,
    IN,
    END,

    HOPE,
    SEE,
    STATUS,
    VALUE,
    ATTRIBUTE,
    CLASS,
    CONTAIN,
    NO,
};

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8,
    line: usize = 1,
    column: usize = 1,
    /// parsed payload for `number` tokens (integer or float, sign included)
    int_value: i64 = 0,
    float_value: f64 = 0,
    is_float: bool = false,
    /// parsed payload for `duration` tokens, normalized to milliseconds
    milliseconds: u64 = 0,
    /// parsed payload for `boolean` tokens
    bool_value: bool = false,

    pub fn is(self: Token, kind: Kind) bool {
        return self.kind == kind;
    }
};

/// Maps a literal word to its reserved token kind, if any.
pub fn keywordKind(text: []const u8) ?Kind {
    const map = .{
        .{ "PROFILE", Kind.PROFILE },
        .{ "BENCHMARK", Kind.BENCHMARK },
        .{ "ON", Kind.ON },
        .{ "OFF", Kind.OFF },
        .{ "RUNTIME", Kind.RUNTIME },
        .{ "OBSERVE", Kind.OBSERVE },
        .{ "BEHAVIOR", Kind.BEHAVIOR },
        .{ "AS", Kind.AS },
        .{ "Human", Kind.Human },
        .{ "Agent", Kind.Agent },
        .{ "I", Kind.I },
        .{ "OPEN", Kind.OPEN },
        .{ "TYPE", Kind.TYPE },
        .{ "INTO", Kind.INTO },
        .{ "CLICK", Kind.CLICK },
        .{ "SELECT", Kind.SELECT },
        .{ "BLUR", Kind.BLUR },
        .{ "GRANT", Kind.GRANT },
        .{ "MOCK", Kind.MOCK },
        .{ "GET", Kind.GET },
        .{ "POST", Kind.POST },
        .{ "WITH", Kind.WITH },
        .{ "JSON", Kind.JSON },
        .{ "SAVE", Kind.SAVE },
        .{ "RESPONSE", Kind.RESPONSE },
        .{ "LET", Kind.LET },
        .{ "FOR", Kind.FOR },
        .{ "EACH", Kind.EACH },
        .{ "IN", Kind.IN },
        .{ "END", Kind.END },
        .{ "HOPE", Kind.HOPE },
        .{ "SEE", Kind.SEE },
        .{ "STATUS", Kind.STATUS },
        .{ "VALUE", Kind.VALUE },
        .{ "ATTRIBUTE", Kind.ATTRIBUTE },
        .{ "CLASS", Kind.CLASS },
        .{ "CONTAIN", Kind.CONTAIN },
        .{ "NO", Kind.NO },
        .{ "true", Kind.boolean },
        .{ "false", Kind.boolean },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
}
