pub const Iterator = struct {
    path_buf: []u8,
    path_env: if (builtin.os.tag == .windows) [:0]const u16 else []const u8,
    pos: usize = 0,

    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    const extensions = [_][]const u8{ ".exe", ".cmd", ".bat", ".com" };

    pub fn fromEnv(path_buf: []u8) Iterator {
        return if (builtin.os.tag == .windows) .{
            .path_buf = path_buf,
            .path_env = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("PATH")) orelse &.{},
        } else .{
            .path_buf = path_buf,
            .path_env = std.posix.getenv("PATH") orelse "",
        };
    }

    pub fn next(it: *Iterator, name: []const u8) error{Reported}!?[:0]const u8 {
        if (builtin.os.tag == .windows) {
            while (it.pos < it.path_env.len) {
                const start = it.pos;
                const end = std.mem.indexOfScalarPos(u16, it.path_env, start, ';') orelse it.path_env.len;
                it.pos = end + 1;
                const dir_w = it.path_env[start..end];
                if (dir_w.len == 0) continue;
                var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
                const dir_len = std.unicode.wtf16LeToWtf8(&dir_buf, dir_w);
                const dir = dir_buf[0..dir_len];
                const expanded_len = pathenv.expandLen(dir);
                if (!hasExt(name)) {
                    for (extensions) |ext| {
                        if (try it.checkPath(dir, expanded_len, name, ext)) |result| return result;
                    }
                } else {
                    if (try it.checkPath(dir, expanded_len, name, "")) |result| return result;
                }
            }
        } else {
            while (it.pos < it.path_env.len) {
                const start = it.pos;
                const end = std.mem.indexOfScalarPos(u8, it.path_env, start, ':') orelse it.path_env.len;
                it.pos = end + 1;
                const dir = it.path_env[start..end];
                if (dir.len == 0) continue;
                const expanded_len = pathenv.expandLen(dir);
                if (try it.checkPath(dir, expanded_len, name, "")) |result| return result;
            }
        }
        return null;
    }

    fn hasExt(name: []const u8) bool {
        for (extensions) |ext| {
            if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
        }
        return false;
    }

    fn checkPath(it: *Iterator, dir: []const u8, expanded_len: usize, name: []const u8, ext: []const u8) error{Reported}!?[:0]const u8 {
        if (expanded_len + 1 + name.len + ext.len + 1 > it.path_buf.len) {
            std.log.warn("path too long for buffer: {s}{c}{s}{s}", .{ dir, sep, name, ext });
            return null;
        }
        pathenv.expandInto(dir, it.path_buf[0..expanded_len]);
        var pos = expanded_len;

        if (pos > 0 and it.path_buf[pos - 1] != '/' and it.path_buf[pos - 1] != sep) {
            it.path_buf[pos] = sep;
            pos += 1;
        }

        @memcpy(it.path_buf[pos..][0..name.len], name);
        pos += name.len;
        @memcpy(it.path_buf[pos..][0..ext.len], ext);
        pos += ext.len;
        it.path_buf[pos] = 0;

        const path = it.path_buf[0..pos :0];
        std.fs.cwd().access(path, .{}) catch |err| switch (err) {
            error.FileNotFound,
            error.AccessDenied,
            error.PermissionDenied,
            error.BadPathName,
            error.NameTooLong,
            => return null,
            else => return reportError("access '{s}' failed with {t}", .{ path, err }),
        };
        return path;
    }
};

fn reportError(comptime fmt: []const u8, args: anytype) error{Reported} {
    std.log.err(fmt, args);
    return error.Reported;
}

const builtin = @import("builtin");
const pathenv = @import("pathenv.zig");
const std = @import("std");
