/// Allocate and return a fully expanded copy of `path`.
/// Caller owns the returned slice.
pub fn expand(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    const len = expandLen(path);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    expandInto(path, buf);
    return buf;
}

/// Returns the length of `path` after all expansions are applied.
pub fn expandLen(path: []const u8) usize {
    return if (builtin.os.tag == .windows)
        expandLenWindows(path)
    else
        expandLenPosix(path);
}

/// Writes the expanded form of `path` into `out_buf`.
/// `out_buf` must `expandLen(path)` bytes long.
/// No allocation is performed.
pub fn expandInto(path: []const u8, out_buf: []u8) void {
    if (builtin.os.tag == .windows)
        expandIntoWindows(path, out_buf)
    else
        expandIntoPosix(path, out_buf);
}

fn expandLenPosix(path: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    if (i < path.len and path[i] == '~') {
        len += if (std.posix.getenv("HOME")) |h| h.len else 0;
        i += 1;
    }
    while (i < path.len) {
        if (path[i] == '$') {
            i += 1;
            const name, const after = parseName(path, i);
            len += if (std.posix.getenv(name)) |v| v.len else 1 + name.len;
            i = after;
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

fn expandIntoPosix(path: []const u8, out_buf: []u8) void {
    std.debug.assert(expandLenPosix(path) == out_buf.len);
    var out: usize = 0;
    var i: usize = 0;

    if (i < path.len and path[i] == '~') {
        if (std.posix.getenv("HOME")) |home| {
            @memcpy(out_buf[out..][0..home.len], home);
            out += home.len;
        }
        i += 1;
    }

    while (i < path.len) {
        if (path[i] == '$') {
            i += 1;
            const name, const after = parseName(path, i);
            if (std.posix.getenv(name)) |value| {
                @memcpy(out_buf[out..][0..value.len], value);
                out += value.len;
            } else {
                out_buf[out] = '$';
                out += 1;
                @memcpy(out_buf[out..][0..name.len], name);
                out += name.len;
            }
            i = after;
        } else {
            out_buf[out] = path[i];
            out += 1;
            i += 1;
        }
    }
}

fn expandLenWindows(path: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;

    while (i < path.len) {
        if (path[i] == '%') {
            const start = i + 1;
            if (std.mem.indexOfScalarPos(u8, path, start, '%')) |end| {
                const name = path[start..end];
                if (windowsGetenv(name)) |v16| {
                    len += utf16LeUtf8Len(v16);
                } else {
                    len += end + 1 - i; // keep literal %VAR%
                }
                i = end + 1;
                continue;
            }
        }
        len += 1;
        i += 1;
    }

    return len;
}

fn expandIntoWindows(path: []const u8, out_buf: []u8) void {
    std.debug.assert(expandLenWindows(path) == out_buf.len);
    var out: usize = 0;
    var i: usize = 0;

    while (i < path.len) {
        if (path[i] == '%') {
            const start = i + 1;
            if (std.mem.indexOfScalarPos(u8, path, start, '%')) |end| {
                const name = path[start..end];
                if (windowsGetenv(name)) |v16| {
                    const written = std.unicode.utf16LeToUtf8(out_buf[out..], v16) catch unreachable;
                    out += written;
                } else {
                    const lit = path[i .. end + 1];
                    @memcpy(out_buf[out..][0..lit.len], lit);
                    out += lit.len;
                }
                i = end + 1;
                continue;
            }
        }
        out_buf[out] = path[i];
        out += 1;
        i += 1;
    }
}

/// Parse a variable name starting at `i` in `path`.
/// Handles both `${VAR}` and `$VAR` forms.
/// Returns .{ name_slice, index_after }.
fn parseName(path: []const u8, i: usize) struct { []const u8, usize } {
    if (i < path.len and path[i] == '{') {
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, path, start, '}') orelse
            return .{ path[start..], path.len }; // malformed: consume to end
        return .{ path[start..end], end + 1 };
    }
    const start = i;
    var j = start;
    while (j < path.len and (std.ascii.isAlphanumeric(path[j]) or path[j] == '_')) : (j += 1) {}
    return .{ path[start..j], j };
}

/// Zero-allocation env lookup for Windows, returning a UTF-16LE slice.
/// Names longer than 1024 chars return null.
fn windowsGetenv(name: []const u8) ?[]const u16 {
    comptime std.debug.assert(builtin.os.tag == .windows);
    const max_name = 1024;
    var name16_buf: [max_name + 1]u16 = undefined;
    // name.len is an upper bound on the UTF-16 output length, so this
    // guarantees utf8ToUtf16Le won't write more than 256 code units.
    if (name.len > max_name) return null;
    const len = std.unicode.utf8ToUtf16Le(&name16_buf, name) catch return null;
    name16_buf[len] = 0;
    return std.process.getenvW(name16_buf[0..len :0]);
}

/// Number of UTF-8 bytes needed to encode a UTF-16LE string (handles surrogates).
fn utf16LeUtf8Len(utf16: []const u16) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < utf16.len) {
        var cp: u21 = utf16[i];
        i += 1;
        if (cp >= 0xD800 and cp < 0xDC00 and i < utf16.len) {
            const low: u21 = utf16[i];
            if (low >= 0xDC00 and low < 0xE000) {
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00);
                i += 1;
            }
        }
        len += std.unicode.utf8CodepointSequenceLength(@intCast(cp)) catch 1;
    }
    return len;
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Small helper used throughout the tests: expand path and compare to expected.
fn expectExpanded(path: []const u8, expected: []const u8) !void {
    const len = expandLen(path);
    try testing.expectEqual(expected.len, len);
    var buf: [4096]u8 = undefined;
    expandInto(path, buf[0..len]);
    try testing.expectEqualStrings(expected, buf[0..len]);
}

// ── plain paths (no expansion) ────────────────────────────────────────────────

test "plain path is returned unchanged" {
    try expectExpanded("/usr/local/bin", "/usr/local/bin");
}

test "empty string" {
    try expectExpanded("", "");
}

test "path with no special chars" {
    try expectExpanded("/foo/bar/baz", "/foo/bar/baz");
}

// ── tilde (POSIX only) ────────────────────────────────────────────────────────

test "bare tilde expands to HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    try expectExpanded("~", home);
}

test "tilde followed by path segment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}/bin", .{home});
    try expectExpanded("~/bin", expected);
}

test "tilde only expands at position 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded("/foo/~/bar", "/foo/~/bar");
}

// ── $VAR / ${VAR} (POSIX) ─────────────────────────────────────────────────────

test "$VAR expands to its value" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}/bin", .{home});
    try expectExpanded("$HOME/bin", expected);
}

test "${VAR} expands to its value" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}/bin", .{home});
    try expectExpanded("${HOME}/bin", expected);
}

test "unknown $VAR is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded("$_DEFINITELY_NOT_SET_XYZ", "$_DEFINITELY_NOT_SET_XYZ");
}

test "unknown ${VAR} is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded("${_DEFINITELY_NOT_SET_XYZ}/bin", "$_DEFINITELY_NOT_SET_XYZ/bin");
}

test "bare $ with no name is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded("$", "$");
}

test "$ followed by non-identifier chars is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded("$!/bin", "$!/bin");
}

test "multiple $VAR expansions in one path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    const path_val = std.posix.getenv("PATH") orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}:{s}", .{ home, path_val });
    try expectExpanded("$HOME:$PATH", expected);
}

test "adjacent $VAR expansions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const home = std.posix.getenv("HOME") orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{s}{s}", .{ home, home });
    try expectExpanded("$HOME$HOME", expected);
}

test "malformed ${VAR without closing brace does not crash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const path = "${UNCLOSED";
    const len = expandLen(path);
    var buf: [4096]u8 = undefined;
    expandInto(path, buf[0..len]);
}

// ── %VAR% (Windows) ───────────────────────────────────────────────────────────

test "%VAR% expands to its value on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const profile16 = windowsGetenv("USERPROFILE") orelse return error.SkipZigTest;
    var profile_buf: [4096]u8 = undefined;
    const plen = try std.unicode.utf16LeToUtf8(&profile_buf, profile16);
    var expected_buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}\\bin", .{profile_buf[0..plen]});
    try expectExpanded("%USERPROFILE%\\bin", expected);
}

test "unknown %VAR% is kept literal on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExpanded("%_DEFINITELY_NOT_SET_XYZ%", "%_DEFINITELY_NOT_SET_XYZ%");
}

test "lone % with no closing % is kept literal on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExpanded("%NOCLOSE", "%NOCLOSE");
}

test "multiple %VAR% expansions in one path on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const profile16 = windowsGetenv("USERPROFILE") orelse return error.SkipZigTest;
    const sys16 = windowsGetenv("SystemRoot") orelse return error.SkipZigTest;
    var pb: [4096]u8 = undefined;
    var sb: [4096]u8 = undefined;
    const plen = try std.unicode.utf16LeToUtf8(&pb, profile16);
    const slen = try std.unicode.utf16LeToUtf8(&sb, sys16);
    var expected_buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s};{s}", .{ pb[0..plen], sb[0..slen] });
    try expectExpanded("%USERPROFILE%;%SystemRoot%", expected);
}

// ── length / write consistency ────────────────────────────────────────────────

test "expandLen always matches expandInto output length on POSIX" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const cases = [_][]const u8{
        "",       "~",           "~/bin",             "/plain/path",
        "$HOME",  "${HOME}/lib", "$HOME/$_UNSET/end", "$",
        "$!/bin", "${UNCLOSED",
    };
    for (cases) |c| {
        const len = expandLen(c);
        var buf: [4096]u8 = undefined;
        expandInto(c, buf[0..len]);
    }
}

test "expandLen always matches expandInto output length on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const cases = [_][]const u8{
        "",                   "C:\\plain\\path",
        "%USERPROFILE%\\bin", "%_UNSET%\\bin",
        "%NOCLOSE",           "%SystemRoot%;%USERPROFILE%",
    };
    for (cases) |c| {
        const len = expandLen(c);
        var buf: [4096]u8 = undefined;
        expandInto(c, buf[0..len]);
    }
}

const builtin = @import("builtin");
const std = @import("std");
