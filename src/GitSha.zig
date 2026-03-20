const GitSha = @This();

bytes: [20]u8,

pub fn fromHex(hex_chars: *const [40]u8) ?GitSha {
    var result: GitSha = .{ .bytes = undefined };
    const b = std.fmt.hexToBytes(&result.bytes, hex_chars) catch return null;
    std.debug.assert(b.len == 20);
    return result;
}

pub fn hex(self: *const GitSha) [40]u8 {
    var buf: [40]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{x}", .{&self.bytes}) catch unreachable;
    std.debug.assert(result.len == 40);
    return buf;
}

pub fn format(self: *const GitSha, writer: *std.Io.Writer) error{WriteFailed}!void {
    const h = self.hex();
    try writer.writeAll(&h);
}

const std = @import("std");
