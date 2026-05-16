pub const Extent = struct { start: usize, end: usize };

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub fn extent(token: *const Token) Extent {
        return .{ .start = token.start, .end = token.end };
    }

    pub const Tag = enum {
        eof,
        invalid,
        @"{",
        @"}",
        @"[",
        @"]",
        @":",
        @",",
        true,
        false,
        null,
        string,
        number,
        pub fn desc(tag: Tag) [:0]const u8 {
            return switch (tag) {
                .eof => "EOF",
                .invalid => "INVALID_TOKEN",
                .@"{" => "\"{\"",
                .@"}" => "\"}\"",
                .@"[" => "\"[\"",
                .@"]" => "\"]\"",
                .@":" => "\":\"",
                .@"," => "\",\"",
                .true => "true",
                .false => "false",
                .null => "null",
                .string => "string",
                .number => "number",
            };
        }
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "false", .false },
        .{ "true", .true },
        .{ "null", .null },
    });
};

pub fn lex(text: []const u8, lex_start: usize) Token {
    const State = union(enum) {
        start,
        @"-": usize,
        number: usize,
        string_literal: usize,
        identifier: usize,
    };

    var index = lex_start;
    var state: State = .start;

    while (true) {
        if (index >= text.len) return switch (state) {
            .start => .{ .tag = .eof, .start = index, .end = index },
            .@"-" => |start| .{ .tag = .invalid, .start = start, .end = index },
            .number => |start| .{ .tag = .number, .start = start, .end = index },
            .string_literal => |start| .{ .tag = .invalid, .start = start, .end = index },
            .identifier => |start| {
                const string = text[start..index];
                return .{
                    .tag = if (Token.keywords.get(string)) |tag| tag else .invalid,
                    .start = start,
                    .end = index,
                };
            },
        };
        switch (state) {
            .start => {
                switch (text[index]) {
                    ' ', '\n', '\t', '\r' => index += 1,
                    '"' => {
                        state = .{ .string_literal = index };
                        index += 1;
                    },
                    '[' => return .{ .tag = .@"[", .start = index, .end = index + 1 },
                    ']' => return .{ .tag = .@"]", .start = index, .end = index + 1 },
                    ',' => return .{ .tag = .@",", .start = index, .end = index + 1 },
                    ':' => return .{ .tag = .@":", .start = index, .end = index + 1 },
                    '{' => return .{ .tag = .@"{", .start = index, .end = index + 1 },
                    '}' => return .{ .tag = .@"}", .start = index, .end = index + 1 },
                    '-' => {
                        state = .{ .@"-" = index };
                        index += 1;
                    },
                    '0'...'9' => {
                        state = .{ .number = index };
                        index += 1;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .{ .identifier = index };
                        index += 1;
                    },
                    else => return .{ .tag = .invalid, .start = index, .end = index + 1 },
                }
            },
            .@"-" => |start| switch (text[index]) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    state = .{ .number = start };
                    index += 1;
                },
                else => return .{ .tag = .invalid, .start = start, .end = index },
            },
            .number => |start| switch (text[index]) {
                '_', '.', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    index += 1;
                },
                else => return .{ .tag = .number, .start = start, .end = index },
            },
            .string_literal => |start| switch (text[index]) {
                '"' => return .{ .tag = .string, .start = start, .end = index + 1 },
                '\n' => return .{ .tag = .invalid, .start = start, .end = index },
                '\\' => index += 2, // skip escaped character
                else => index += 1,
            },
            .identifier => |start| switch (text[index]) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => index += 1,
                else => {
                    const string = text[start..index];
                    return .{
                        .tag = if (Token.keywords.get(string)) |tag| tag else .invalid,
                        .start = start,
                        .end = index,
                    };
                },
            },
        }
    }
}

/// Skip a single JSON value (string, number, bool, null, object, or array).
pub fn skipValue(text: []const u8, offset: usize) ?usize {
    const token = lex(text, offset);
    return switch (token.tag) {
        .string, .number, .true, .false, .null => token.end,
        .@"{" => skipCompound(text, token.end, .@"{"),
        .@"[" => skipCompound(text, token.end, .@"["),
        else => null,
    };
}

fn skipCompound(text: []const u8, start: usize, open: Token.Tag) ?usize {
    const close: Token.Tag = if (open == .@"{") .@"}" else .@"]";
    var depth: usize = 1;
    var pos = start;
    while (depth > 0) {
        const token = lex(text, pos);
        if (token.tag == .eof or token.tag == .invalid) return null;
        if (token.tag == open) depth += 1;
        if (token.tag == close) depth -= 1;
        pos = token.end;
    }
    return pos;
}

pub const ParseError = struct {
    at: usize,
    why: Why,
    pub const Why = union(enum) {
        unexpected_token: UnexpectedToken,
        invalid_value,
    };
    pub const UnexpectedToken = struct { expected: [:0]const u8, got: Token.Tag };

    pub fn set(err: *ParseError, at: usize, why: Why) error{InvalidJson} {
        err.* = .{ .at = at, .why = why };
        return error.InvalidJson;
    }

    pub fn formatWhy(why: Why, w: *std.Io.Writer) error{WriteFailed}!void {
        switch (why) {
            .unexpected_token => |u| try w.print("expected {s}, got {s}", .{ u.expected, u.got.desc() }),
            .invalid_value => try w.writeAll("invalid JSON value"),
        }
    }
};

pub const Loc = struct {
    start: usize,
    limit: usize,
    pub fn len(loc: Loc) usize {
        return loc.limit - loc.start;
    }
    pub fn slice(loc: Loc, text: []const u8) []const u8 {
        return text[loc.start..loc.limit];
    }
};

pub const ObjectIterator = struct {
    text: []const u8,
    pos: usize,
    is_first: bool,

    pub fn init(text: []const u8, lex_start: usize, err: *ParseError) error{InvalidJson}!ObjectIterator {
        const open = lex(text, lex_start);
        if (open.tag != .@"{")
            return err.set(open.start, .{ .unexpected_token = .{ .expected = "\"{\"", .got = open.tag } });
        return initOpened(text, open.end);
    }

    pub fn initOpened(text: []const u8, inside_pos: usize) ObjectIterator {
        return .{ .text = text, .pos = inside_pos, .is_first = true };
    }

    pub fn next(it: *ObjectIterator, err: *ParseError) error{InvalidJson}!?[]const u8 {
        const key_lex_pos = blk: {
            const token = lex(it.text, it.pos);
            if (token.tag == .@"}") return null;
            if (it.is_first) break :blk it.pos;
            if (token.tag != .@",")
                return err.set(token.start, .{ .unexpected_token = .{ .expected = "\",\" or \"}\"", .got = token.tag } });
            break :blk token.end;
        };

        const key_token = lex(it.text, key_lex_pos);
        if (key_token.tag != .string)
            return err.set(key_token.start, .{ .unexpected_token = .{ .expected = "field key string", .got = key_token.tag } });
        const key = it.text[key_token.start + 1 .. key_token.end - 1];

        const colon = lex(it.text, key_token.end);
        if (colon.tag != .@":")
            return err.set(colon.start, .{ .unexpected_token = .{ .expected = "\":\"", .got = colon.tag } });
        it.pos = colon.end;
        it.is_first = false;
        return key;
    }

    pub fn takeString(it: *ObjectIterator, err: *ParseError) error{InvalidJson}!Loc {
        const tok = lex(it.text, it.pos);
        if (tok.tag != .string)
            return err.set(tok.start, .{ .unexpected_token = .{ .expected = "string value", .got = tok.tag } });
        it.pos = tok.end;
        return .{ .start = tok.start + 1, .limit = tok.end - 1 };
    }

    pub fn skip(it: *ObjectIterator, err: *ParseError) error{InvalidJson}!void {
        it.pos = skipValue(it.text, it.pos) orelse return err.set(it.pos, .invalid_value);
    }
};

const std = @import("std");
